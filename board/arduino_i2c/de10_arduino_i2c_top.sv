`timescale 1ns/1ps
`default_nettype none
// DE10-Lite <-> Uno R3: SW9=0 reads; SW9=1 writes SW[7:0].
// One transaction every five seconds. SDA/SCL only drive low or release.
module de10_arduino_i2c_top #(
    parameter integer INTERVAL_CYCLES = 250_000_000, // 5 s at 50 MHz
    parameter integer HALF_PERIOD = 2500,           // approximately 10 kHz I2C
    parameter integer DEBOUNCE_CYCLES = 1_000_000,  // 20 ms stable switches
    parameter integer BLINK_HALF_CYCLES = 25_000_000,
    parameter [6:0] ARDUINO_ADDRESS = 7'h42
)(
    input wire MAX10_CLK1_50,
    input wire KEY0,
    input wire [9:0] SW,
    inout wire I2C_SDA,
    inout wire I2C_SCL,
    output wire [9:0] LEDR,
    output wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5
);
    wire rst_n;
    reset_release resetter(.clk(MAX10_CLK1_50), .key_n(KEY0), .rst_n(rst_n));

    // SW8 is deliberately unused: physical gap between payload and mode.
    wire unused_sw8 = SW[8];
    (* ASYNC_REG = "TRUE" *) reg [8:0] switch_meta, switch_sync;
    reg [8:0] switch_candidate, switch_stable;
    reg [31:0] debounce_count;
    always @(posedge MAX10_CLK1_50 or negedge rst_n) begin
        if (!rst_n) begin
            switch_meta <= 0;
            switch_sync <= 0;
            switch_candidate <= 0;
            switch_stable <= 0;
            debounce_count <= 0;
        end else begin
            switch_meta <= {SW[9], SW[7:0]};
            switch_sync <= switch_meta;
            if (switch_sync != switch_candidate) begin
                switch_candidate <= switch_sync;
                debounce_count <= 0;
            end else if (debounce_count < DEBOUNCE_CYCLES - 1) begin
                debounce_count <= debounce_count + 1'b1;
            end else begin
                switch_stable <= switch_candidate;
            end
        end
    end

    reg [31:0] interval_count;
    wire interval_tick = interval_count == INTERVAL_CYCLES - 1;
    always @(posedge MAX10_CLK1_50 or negedge rst_n) begin
        if (!rst_n) interval_count <= 0;
        else if (interval_tick) interval_count <= 0;
        else interval_count <= interval_count + 1'b1;
    end

    wire scl_low, sda_low;
    assign I2C_SDA = sda_low ? 1'b0 : 1'bz;
    assign I2C_SCL = scl_low ? 1'b0 : 1'bz;
    reg valid, write_en;
    reg [7:0] reg_addr;
    reg [31:0] wdata;
    wire [31:0] rdata;
    wire unused_ready, unused_irq;
    wire unused_rdata = ^{rdata[31:8], rdata[7:6], rdata[0]};
    i2c_controller core(
        .clk(MAX10_CLK1_50), .rst_n(rst_n),
        .reg_valid(valid), .reg_write(write_en), .reg_addr(reg_addr),
        .reg_wdata(wdata), .reg_ready(unused_ready), .reg_rdata(rdata),
        .scl_i(I2C_SCL), .sda_i(I2C_SDA),
        .scl_low(scl_low), .sda_low(sda_low), .irq(unused_irq)
    );

    localparam [3:0] CONFIG_DIV=0, CONFIG_TIMEOUT=1, WAIT_INTERVAL=2,
        LOAD_ADDRESS=3, SEND_ADDRESS=4, WAIT_ADDRESS=5,
        LOAD_PAYLOAD=6, SEND_PAYLOAD=7, READ_PAYLOAD=8,
        WAIT_PAYLOAD=9, SAVE_READ=10, SEND_STOP=11, WAIT_STOP=12;
    reg [3:0] state;
    reg transfer_write;
    reg [7:0] transfer_byte, received_byte;
    reg succeeded, failed;
    wire command_failed = rdata[5] || rdata[3] || rdata[2];

    // Register offsets and commands are defined by rtl/i2c_controller.sv.
    // Every write state lasts exactly one clock edge; polls never write.
    always @* begin
        valid = 1'b0;
        write_en = 1'b0;
        reg_addr = 8'h04;
        wdata = 0;
        case (state)
            CONFIG_DIV: begin
                valid=1; write_en=1; reg_addr=8'h10; wdata=HALF_PERIOD;
            end
            CONFIG_TIMEOUT: begin
                valid=1; write_en=1; reg_addr=8'h18; wdata=5_000_000; // 100 ms/command
            end
            LOAD_ADDRESS: begin
                valid=1; write_en=1; reg_addr=8'h08;
                wdata={24'b0, ARDUINO_ADDRESS, !transfer_write};
            end
            SEND_ADDRESS: begin
                valid=1; write_en=1; reg_addr=8'h00; wdata=32'h05; // START | WRITE
            end
            LOAD_PAYLOAD: begin
                valid=1; write_en=1; reg_addr=8'h08; wdata={24'b0, transfer_byte};
            end
            SEND_PAYLOAD: begin
                valid=1; write_en=1; reg_addr=8'h00; wdata=32'h06; // WRITE | STOP
            end
            READ_PAYLOAD: begin
                valid=1; write_en=1; reg_addr=8'h00; wdata=32'h0a; // READ | STOP; final NACK
            end
            WAIT_ADDRESS, WAIT_PAYLOAD, WAIT_STOP: valid=1;
            SAVE_READ: begin valid=1; reg_addr=8'h0c; end
            SEND_STOP: begin
                valid=1; write_en=1; reg_addr=8'h00; wdata=32'h02;
            end
            default: begin end
        endcase
    end

    always @(posedge MAX10_CLK1_50 or negedge rst_n) begin
        if (!rst_n) begin
            state <= CONFIG_DIV;
            transfer_write <= 0;
            transfer_byte <= 0;
            received_byte <= 0;
            succeeded <= 0;
            failed <= 0;
        end else begin
            case (state)
                CONFIG_DIV: state <= CONFIG_TIMEOUT;
                CONFIG_TIMEOUT: state <= WAIT_INTERVAL;
                WAIT_INTERVAL: if (interval_tick) begin
                    // Freeze both direction and payload until STOP completes.
                    transfer_write <= switch_stable[8];
                    transfer_byte <= switch_stable[7:0];
                    state <= LOAD_ADDRESS;
                end
                LOAD_ADDRESS: state <= SEND_ADDRESS;
                SEND_ADDRESS: state <= WAIT_ADDRESS;
                WAIT_ADDRESS: if (rdata[1]) begin
                    if (command_failed) begin
                        succeeded <= 0;
                        failed <= 1;
                        // NACK can leave SCL held low; explicitly end that transfer.
                        // The core watchdog already releases both pins on timeout.
                        state <= rdata[4] ? SEND_STOP : WAIT_INTERVAL;
                    end else begin
                        state <= transfer_write ? LOAD_PAYLOAD : READ_PAYLOAD;
                    end
                end
                LOAD_PAYLOAD: state <= SEND_PAYLOAD;
                SEND_PAYLOAD, READ_PAYLOAD: state <= WAIT_PAYLOAD;
                WAIT_PAYLOAD: if (rdata[1]) begin
                    if (command_failed) begin
                        succeeded <= 0;
                        failed <= 1;
                        state <= rdata[4] ? SEND_STOP : WAIT_INTERVAL;
                    end else if (transfer_write) begin
                        succeeded <= 1;
                        failed <= 0;
                        state <= WAIT_INTERVAL;
                    end else begin
                        state <= SAVE_READ;
                    end
                end
                SAVE_READ: begin
                    received_byte <= rdata[7:0];
                    succeeded <= 1;
                    failed <= 0;
                    state <= WAIT_INTERVAL;
                end
                SEND_STOP: state <= WAIT_STOP;
                WAIT_STOP: if (rdata[1]) state <= WAIT_INTERVAL;
                default: begin
                    succeeded <= 0;
                    failed <= 1;
                    state <= SEND_STOP;
                end
            endcase
        end
    end

    reg [31:0] blink_count;
    reg blink_on;
    always @(posedge MAX10_CLK1_50 or negedge rst_n) begin
        if (!rst_n) begin blink_count<=0; blink_on<=1; end
        else if (!failed) begin blink_count<=0; blink_on<=1; end
        else if (blink_count == BLINK_HALF_CYCLES - 1) begin
            blink_count<=0;
            blink_on<=!blink_on;
        end else blink_count<=blink_count+1'b1;
    end
    assign LEDR = {succeeded, (failed && blink_on), received_byte};

    // Eight rounds of shift/add-3 convert 0..255 to three decimal digits.
    function automatic [11:0] to_bcd(input [7:0] value);
        reg [11:0] bcd;
        integer bit_number;
        begin
            bcd=0;
            for (bit_number=7; bit_number>=0; bit_number=bit_number-1) begin
                if (bcd[3:0]>=4'd5) bcd[3:0]=bcd[3:0]+4'd3;
                if (bcd[7:4]>=4'd5) bcd[7:4]=bcd[7:4]+4'd3;
                if (bcd[11:8]>=4'd5) bcd[11:8]=bcd[11:8]+4'd3;
                bcd={bcd[10:0], value[bit_number]};
            end
            to_bcd=bcd;
        end
    endfunction
    // Active low; bit 7 is decimal point, bits 6..0 are g..a.
    function automatic [7:0] decimal_segments(input [3:0] digit);
        begin
            case (digit)
                0: decimal_segments=8'hc0;
                1: decimal_segments=8'hf9;
                2: decimal_segments=8'ha4;
                3: decimal_segments=8'hb0;
                4: decimal_segments=8'h99;
                5: decimal_segments=8'h92;
                6: decimal_segments=8'h82;
                7: decimal_segments=8'hf8;
                8: decimal_segments=8'h80;
                9: decimal_segments=8'h90;
                default: decimal_segments=8'hff;
            endcase
        end
    endfunction
    wire [11:0] received_decimal = to_bcd(received_byte);
    assign HEX0=decimal_segments(received_decimal[3:0]);
    assign HEX1=decimal_segments(received_decimal[7:4]);
    assign HEX2=decimal_segments(received_decimal[11:8]);
    assign HEX3=8'hff;
    assign HEX4=8'hff;
    assign HEX5=8'hff;
endmodule
`default_nettype wire
