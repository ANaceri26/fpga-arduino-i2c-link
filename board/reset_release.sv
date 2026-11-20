`timescale 1ns/1ps
`default_nettype none
module reset_release(input wire clk,input wire key_n,output wire rst_n);
    (* ASYNC_REG="TRUE" *) reg [1:0] pipe=2'b00;
    always @(posedge clk or negedge key_n)
        if(!key_n) pipe<=0; else pipe<={pipe[0],1'b1};
    assign rst_n=pipe[1];
endmodule
`default_nettype wire
