`timescale 1ns / 1ps

// Reference book: "FPGA Prototyping by Verilog Examples"
//                    "Xilinx Spartan-3 Version"
// Authored by: Pong P. Chu
// Published by: Wiley, 2008

// Adapted for use on Basys 3 FPGA with Xilinx Artix-7
// by: David J. Marion aka FPGA Dude

// Modified by: Matt 3/11/2023
//	- change the debounce module & dual port ram module
//  - video_on -> video_off (blanking)
// 27/09/2026
//  - modify for running on vga-playground.com
//  - use gamepad pmod for input
//  - remove debounce module

module text_screen_gen(
    input wire clk, 
    input wire reset,
    input wire video_off,
    input wire [11:0] gamepad_in,
    input wire [9:0] x,
    input wire [9:0] y,
    input wire vsync,
    output reg [5:0] rgb
    );
    
    // signal declaration
    // ascii ROM
    wire [10:0] rom_addr;
    wire [6:0] char_addr;
    wire [3:0] row_addr;
    wire [2:0] bit_addr;
    wire [7:0] font_word;
    wire ascii_bit;

    // tile RAM
    wire we;                    // write enable
    wire we2;                    // write enable
    wire [11:0] addr_r, addr_w;
    wire [11:0] addr_r2, addr_w2;
    wire [6:0] din, dout;
    wire [5:0] din2, dout2;
    // 80-by-30 tile map
    parameter MAX_X = 80;   // 640 pixels / 8 data bits = 80
    parameter MAX_Y = 30;   // 480 pixels / 16 data rows = 30

    // cursor
    reg [6:0] cur_x_reg;
    wire [6:0] cur_x_next;
    reg [4:0] cur_y_reg;
    wire [4:0] cur_y_next;
    wire move_xl_tick, move_yu_tick, move_xr_tick, move_yd_tick, cursor_on;
    reg [31:0] delay_color = 6'b000000;

    // delayed pixel count by 2clk
    reg [9:0] pix_x1_reg, pix_y1_reg;
    reg [9:0] pix_x2_reg, pix_y2_reg;
    // object output signals
    wire [5:0] text_rgb, text_rev_rgb;

    // canvas area
    // parameter canvas_u = 0, canvas_d = 25, canvas_l = 0, canvas_r = 80;

    // color palatte
    reg [5:0] selected_color = 6'b111111;
    reg [5:0] color_palatte[8][2];
    wire [2:0] palatte_index_i;
    wire palatte_index_j;
    wire on_color_palatte;
    wire cursor_on_color;
    wire cursor_in_palatte;
    wire cursor_in_color_box;
    parameter palatte_u = 26, palatte_d = 30, palatte_l = 12, palatte_r = 44;

    // color slide bar
    // wire on_color_bar;
    // wire cursor_on_bar;
    // wire cursor_in_color_bar;
    // reg [1:0] color_bar_value[3];
    // parameter bar_u = 24, bar_d = 30, bar_l = 52, bar_r = 64;

    // brush ascii
    reg [6:0] selected_ascii = 7'b1;
    reg [6:0] ascii_palatte[7][2];
    wire [2:0] ascii_index_i;
    wire ascii_index_j;
    wire on_ascii_palatte;
    wire cursor_on_ascii;
    wire cursor_in_ascii_palatte;
    parameter ascii_l = 72, ascii_r = 80, ascii_u = 2, ascii_d = 16;

    // pen
    reg pen_down = 0;
    reg prev_b = 0;

    // move speed based on cursor position
    wire [8:0] move_speed_x;
    wire [8:0] move_speed_y;
    
    // body
    // instantiate debounce for four buttons
	debouncer db_left(.clk(clk),.PB(gamepad_in[5]),.PB_state(),.PB_down(move_xl_tick),.PB_up());
	debouncer db_up(.clk(clk),.PB(gamepad_in[7]),.PB_state(),.PB_down(move_yu_tick),.PB_up());
	debouncer db_down(.clk(clk),.PB(gamepad_in[6]),.PB_state(),.PB_down(move_yd_tick),.PB_up());
	debouncer db_right(.clk(clk),.PB(gamepad_in[4]),.PB_state(),.PB_down(move_xr_tick),.PB_up());
	
    // instantiate the ascii / font rom, 1% of BRAM on Basys3
    ascii_rom a_rom(.clk(clk), .addr(rom_addr), .data(font_word));
    // instantiate dual-port video RAM (2^12-by-7), 2% of BRAM on Basys3
	simpledpmem #(.DATA_SIZE(7), .ADDR_SIZE(12)) 
    dp_ram(.clk(clk),.reset(),.dat_in(din),.wr_adr(addr_w),.wr_en(we),.dat_out(dout),.rd_adr(addr_r));

    simpledpmem #(.DATA_SIZE(6), .ADDR_SIZE(12)) 
    dp_ram2(.clk(clk),.reset(),.dat_in(din2),.wr_adr(addr_w2),.wr_en(we2),.dat_out(dout2),.rd_adr(addr_r2));
     
    initial begin
      for (integer i=0;i<8;i=i+1) begin
        color_palatte[i][0] = (i%2==0) ? 6'b001111: 6'b111100;
        color_palatte[i][1] = (i%2==0) ? 6'b001011: 6'b111000;
      end
      ascii_palatte[0][0] = 7'h01;
      ascii_palatte[0][1] = 7'h58;
      ascii_palatte[1][0] = 7'h2e;
      ascii_palatte[1][1] = 7'h7f;
      for (integer i=0;i<10;i=i+1) begin
        ascii_palatte[i/2 + 2][i&1] = 7'h30 + i;
      end
    end


    // registers
    always @(posedge clk or posedge reset)
        if(reset) begin
            cur_x_reg <= 0;
            cur_y_reg <= 0;
            pix_x1_reg <= 0;
            pix_x2_reg <= 0;
            pix_y1_reg <= 0;
            pix_y2_reg <= 0;
            delay_color <= 0;
        end    
        else begin
            cur_x_reg <= cur_x_next;
            cur_y_reg <= cur_y_next;
            pix_x1_reg <= x;
            pix_x2_reg <= pix_x1_reg;
            pix_y1_reg <= y;
            pix_y2_reg <= pix_y1_reg;

            // select color
            if (cur_y_reg >= palatte_u && cur_y_reg < palatte_d &&
                cur_x_reg >= palatte_l && cur_x_reg < palatte_r &&
                gamepad_in[3]) begin
              selected_color <= color_palatte[(cur_x_reg-palatte_l)>>2][(cur_y_reg-palatte_u)>>1];
            end

            if (gamepad_in[11]) begin
              prev_b <= 1;
              if (!prev_b) pen_down <= pen_down ^ 1;
            end
            else prev_b <= 0;
        end
		
    always @(posedge vsync) begin
      if (delay_color == 0) begin
        delay_color <= 50;
      end 
      else delay_color <= delay_color -1;
    end

    assign on_color_palatte = (pix_y2_reg[8:4] >= palatte_u && pix_y2_reg[8:4] < palatte_d &&
                       pix_x2_reg[9:3] >= palatte_l && pix_x2_reg[9:3] < palatte_r);
    assign palatte_index_i = (pix_x2_reg[9:3]-palatte_l)>>2;
    assign palatte_index_j = (pix_y2_reg[8:4]-palatte_u)>>1;
    assign cursor_on_color = (cur_y_reg[4:1] == pix_y2_reg[8:5] && cur_x_reg[6:2]==pix_x2_reg[9:5] && on_color_palatte);
    assign cursor_in_palatte = (cur_y_reg >= palatte_u && cur_y_reg < palatte_d &&
                              cur_x_reg >= palatte_l && cur_x_reg < palatte_r);
    assign cursor_in_color_box = (cur_y_reg >= palatte_u && cur_y_reg < palatte_d &&
                                  cur_x_reg >= 0 && cur_x_reg < 8);

    assign on_ascii_palatte = (pix_y2_reg[8:4] >= ascii_u && pix_y2_reg[8:4] < ascii_d &&
                               pix_x2_reg[9:3] >= ascii_l && pix_x2_reg[9:3] < ascii_r);
    assign ascii_index_j = (pix_x2_reg[9:3]-ascii_l)>>2;
    assign ascii_index_i = (pix_y2_reg[8:4]-ascii_u)>>1;
    assign cursor_on_ascii = (cur_y_reg[4:1] == pix_y2_reg[8:5] && cur_x_reg[6:2]==pix_x2_reg[9:5] && on_ascii_palatte);
    assign cursor_in_ascii_palatte = (cur_y_reg >= ascii_u && cur_y_reg < ascii_d &&
                                      cur_x_reg >= ascii_l && cur_x_reg < ascii_r);
  
    // tile RAM write
    assign addr_w = {cur_y_reg, cur_x_reg};
    assign we = pen_down;
    assign din = 7'd1;

    // test rom
    // assign addr_r2 = {pix_y1_reg[8:4], pix_x1_reg[9:3]};
    // assign addr_w2 = (gamepad_in[3]) ? {cur_y_reg, cur_x_reg} : {y[8:4], x[9:3]};
    // assign we2 = gamepad_in[3] | (delay_color == 50 && x[2:0]==3'b111 && y[3:0] == 4'b1111
    //                               && pix_x1_reg[9:3]==x[9:3] && pix_y1_reg[8:4]==y[8:4]);
    // assign din2 = (gamepad_in[3]) ? 6'b000011:
    //               (dout2 == 6'b000000 || dout2 == 6'b110000) ? 6'b000011:
    //               (dout2 == 6'b000011) ? 6'b001100:
    //               (dout2 == 6'b001100) ? 6'b110000: 6'b111111;

    // set color
    assign addr_r2= {pix_y1_reg[8:4], pix_x1_reg[9:3]};
    assign addr_w2=addr_w;
    assign we2 = we;
    assign din2 = selected_color;

    // tile RAM read
    // use nondelayed coordinates to form tile RAM address
    assign addr_r = {y[8:4], x[9:3]};
    assign char_addr = dout;
    // font ROM
    assign row_addr = y[3:0];
    assign rom_addr = {char_addr, row_addr};
    // use delayed coordinate to select a bit
    assign bit_addr = pix_x2_reg[2:0];
    assign ascii_bit = font_word[~bit_addr];

    // new cursor position
    assign move_speed_x = (cursor_in_palatte)? 4:
                          (cursor_in_color_box)?  8:1;
    assign move_speed_y = (cursor_in_palatte)? 2:
                          (cursor_in_color_box)?  4:1;
    assign cur_x_next = (move_xr_tick) ? (cur_x_reg + move_speed_x) % MAX_X :    // move right
                        (move_xl_tick) ? (cur_x_reg - move_speed_x + MAX_X) %MAX_X :    // move left
                        cur_x_reg;                          // no move
                                           
    assign cur_y_next = (move_yu_tick) ? (cur_y_reg - move_speed_y + MAX_Y) %MAX_Y :    // move up                        
                        (move_yd_tick) ? (cur_y_reg + move_speed_y) %MAX_Y :    // move down
                        cur_y_reg;                          // no move           
    
    // object signals
    // green over black and reversed video for cursor
    

    assign text_rgb = (ascii_bit) ? ((dout2!=0) ? dout2 : 6'b001100) : 6'b0;
    assign text_rev_rgb = (ascii_bit) ? 6'b0 : selected_color;
    // use delayed coordinates for comparison
    assign cursor_on = (pix_y2_reg[8:4] == cur_y_reg) &&
                       (pix_x2_reg[9:3] == cur_x_reg);

    // rgb multiplexing circuit
    always @(*) begin
        if(video_off)
            rgb = 6'b0;     // blank
        else
            if (pix_y2_reg[8:4] >= palatte_u && pix_y2_reg[8:4] < palatte_d &&
                pix_x2_reg[9:3] >=        0 && pix_x2_reg[9:3] < 8) // show selected color
              if (cursor_in_color_box) rgb=6'b110011;
              else rgb = selected_color;
            else if (on_color_palatte)
              if (cursor_on_color) rgb=6'b110011;
              else rgb = color_palatte[palatte_index_i][palatte_index_j];
            else if(cursor_on)
              rgb = text_rev_rgb;
            else
              rgb = text_rgb;
    end
endmodule