`timescale 1ns/1ps
`default_nettype none
// Single-controller I2C byte engine + a simple 32-bit register port.
// All register writes are full-word, byte-addressed, sampled on clk's rising edge.
module i2c_controller (
    input wire clk, input wire rst_n,
    input wire reg_valid, input wire reg_write,
    input wire [7:0] reg_addr, input wire [31:0] reg_wdata,
    output wire reg_ready, output reg [31:0] reg_rdata,
    input wire scl_i, input wire sda_i,
    output reg scl_low, output reg sda_low, output wire irq
);
    localparam [4:0] IDLE=0, START_PREP=1, START_WAIT=2, START_HIGH=3,
        START_HOLD=4, BIT_SETUP=5, BIT_WAIT=6, BIT_HIGH=7, BIT_FALL=8,
        ACK_SETUP=9, ACK_WAIT=10, ACK_HIGH=11, ACK_FALL=12,
        STOP_SETUP=13, STOP_WAIT=14, STOP_HIGH=15, STOP_FREE=16, FIRST_BIT=17;
    reg [4:0] state;
    reg [15:0] divider, active_div;
    reg [31:0] timeout_cfg, active_timeout, watchdog;
    reg [15:0] timer;
    reg [7:0] tx, shift, rx;
    reg [2:0] bit_index;
    reg do_read, do_stop, send_ack, held, done, nack, timed_out, bad_cmd, irq_en;
    (* ASYNC_REG = "TRUE" *) reg scl_meta, scl_sync, sda_meta, sda_sync;
    wire busy = state != IDLE;
    wire wr = reg_valid && reg_write;
    wire [4:0] command = reg_wdata[4:0];
    wire byte_command = command[2] ^ command[3];
    wire stop_only = command == 5'b00010;
    wire command_ok = (byte_command && (held || command[0])) || stop_only;
    assign reg_ready = 1'b1;
    assign irq = irq_en && done;
    always @* begin
        reg_rdata = 0;
        case (reg_addr)
            8'h04: reg_rdata = {26'b0,bad_cmd,held,timed_out,nack,done,busy};
            8'h08: reg_rdata = {24'b0,tx};
            8'h0c: reg_rdata = {24'b0,rx};
            8'h10: reg_rdata = {16'b0,divider};
            8'h14: reg_rdata = {31'b0,irq_en};
            8'h18: reg_rdata = timeout_cfg;
            8'h1c: reg_rdata = 32'h49324301;
            default: reg_rdata = 0;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_meta <= 1; scl_sync <= 1; sda_meta <= 1; sda_sync <= 1;
        end else begin
            scl_meta <= scl_i; scl_sync <= scl_meta;
            sda_meta <= sda_i; sda_sync <= sda_meta;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; divider<=250; active_div<=250;
            timeout_cfg<=1_000_000; active_timeout<=1_000_000;
            watchdog<=0; timer<=0; tx<=0; shift<=0; rx<=0; bit_index<=7;
            do_read<=0; do_stop<=0; send_ack<=0; held<=0;
            done<=0; nack<=0; timed_out<=0; bad_cmd<=0; irq_en<=0;
            scl_low<=0; sda_low<=0;
        end else begin
            // Sticky status is write-one-to-clear. Completion below wins a same-cycle clear.
            if (wr && reg_addr==8'h04) begin
                if(reg_wdata[1]) done<=0;
                if(reg_wdata[2]) nack<=0;
                if(reg_wdata[3]) timed_out<=0;
                if(reg_wdata[5]) bad_cmd<=0;
            end
            if(wr && reg_addr==8'h14) irq_en<=reg_wdata[0];
            if(!busy) begin
                if(wr && reg_addr==8'h08) tx<=reg_wdata[7:0];
                if(wr && reg_addr==8'h10) divider <= reg_wdata[15:0]<4 ? 16'd4 : reg_wdata[15:0];
                if(wr && reg_addr==8'h18) timeout_cfg <= reg_wdata==0 ? 32'd1 : reg_wdata;
            end
            // Whole-command watchdog, including START/STOP and stretched clocks.
            if(busy) watchdog<=watchdog+1'b1;
            if(busy && watchdog>=active_timeout-1'b1) begin
                state<=IDLE; scl_low<=0; sda_low<=0; held<=0;
                done<=1; timed_out<=1;
            end else case(state)
                IDLE: if(wr && reg_addr==8'h00) begin
                    done<=0; nack<=0; timed_out<=0; bad_cmd<=0;
                    if(!command_ok || reg_wdata[31:5]!=0) begin
                        done<=1; bad_cmd<=1;
                    end else begin
                        active_div<=divider; active_timeout<=timeout_cfg;
                        watchdog<=0; timer<=0; shift<=tx; bit_index<=7;
                        do_read<=command[3]; do_stop<=command[1]; send_ack<=command[4];
                        if(stop_only) begin scl_low<=1; sda_low<=1; state<=STOP_SETUP; end
                        else if(command[0]) begin
                            sda_low<=0; state<=START_PREP;
                            // For a repeated START keep SCL low while releasing SDA.
                        end else begin
                            scl_low<=1; sda_low<=command[3] ? 1'b0 : ~tx[7]; state<=BIT_SETUP;
                        end
                    end
                end
                START_PREP: if(timer==active_div-1'b1) begin
                    timer<=0; scl_low<=0; state<=START_WAIT;
                end else timer<=timer+1'b1;
                START_WAIT: if(scl_sync && sda_sync) begin timer<=0; state<=START_HIGH; end
                START_HIGH: if(timer==active_div-1'b1) begin
                    timer<=0; sda_low<=1; held<=1; state<=START_HOLD;
                end else timer<=timer+1'b1;
                START_HOLD: if(timer==active_div-1'b1) begin
                    timer<=0; scl_low<=1; state<=FIRST_BIT;
                end else timer<=timer+1'b1;
                FIRST_BIT: begin
                    sda_low<=do_read ? 1'b0 : ~shift[7]; state<=BIT_SETUP;
                end
                BIT_SETUP: if(timer==active_div-1'b1) begin
                    timer<=0; scl_low<=0; state<=BIT_WAIT;
                end else timer<=timer+1'b1;
                BIT_WAIT: if(scl_sync) begin timer<=0; state<=BIT_HIGH; end
                BIT_HIGH: if(timer==active_div-1'b1) begin
                    timer<=0; if(do_read) shift[bit_index]<=sda_sync;
                    scl_low<=1; state<=BIT_FALL;
                end else timer<=timer+1'b1;
                BIT_FALL: begin
                    timer<=0;
                    if(bit_index==0) begin
                        sda_low<=do_read && send_ack; state<=ACK_SETUP;
                    end else begin
                        bit_index<=bit_index-1'b1;
                        sda_low<=do_read ? 1'b0 : ~shift[bit_index-1'b1]; state<=BIT_SETUP;
                    end
                end
                ACK_SETUP: if(timer==active_div-1'b1) begin
                    timer<=0; scl_low<=0; state<=ACK_WAIT;
                end else timer<=timer+1'b1;
                ACK_WAIT: if(scl_sync) begin timer<=0; state<=ACK_HIGH; end
                ACK_HIGH: if(timer==active_div-1'b1) begin
                    timer<=0; if(!do_read) nack<=sda_sync;
                    if(do_read) rx<=shift;
                    scl_low<=1; state<=ACK_FALL;
                end else timer<=timer+1'b1;
                ACK_FALL: begin
                    timer<=0;
                    if(do_stop) begin sda_low<=1; state<=STOP_SETUP; end
                    else begin sda_low<=0; done<=1; state<=IDLE; end
                end
                STOP_SETUP: if(timer==active_div-1'b1) begin
                    timer<=0; scl_low<=0; state<=STOP_WAIT;
                end else timer<=timer+1'b1;
                STOP_WAIT: if(scl_sync) begin timer<=0; state<=STOP_HIGH; end
                STOP_HIGH: if(timer==active_div-1'b1) begin
                    timer<=0; sda_low<=0; state<=STOP_FREE;
                end else timer<=timer+1'b1;
                STOP_FREE: if(!scl_sync || !sda_sync) timer<=0;
                else if(timer==active_div-1'b1) begin
                    held<=0; done<=1; state<=IDLE; timer<=0;
                end else timer<=timer+1'b1;
                default: begin state<=IDLE; scl_low<=0; sda_low<=0; held<=0; end
            endcase
        end
    end
endmodule
`default_nettype wire
