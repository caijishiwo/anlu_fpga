/************************************************************\
**	Copyright (c) 2012-2025 Anlogic Inc.
**	All Right Reserved.
\************************************************************/
/************************************************************\
**	Build time: Sep 07 2026 14:53:44
**	TD version	:	6.2.168116
************************************************************/
module UART_0
(
  input                         clk,
  input                         rst_n,
  output                        rx_vld,
  output  [7:0]                 rx_data,
  output                        rx_err,
  input                         rxd,
  output                        tx_rdy,
  input                         tx_en,
  input   [7:0]                 tx_data,
  output                        txd
);

  uart_477e91eaaa73
  #(
      .CLK_DIV_NUM(27),
      .DATA_BIT(8),
      .PARITY_BIT("None"),
      .STOP_BIT("1")
  )uart_477e91eaaa73_Inst
  (
      .clk(clk),
      .rst_n(rst_n),
      .rx_vld(rx_vld),
      .rx_data(rx_data),
      .rx_err(rx_err),
      .rxd(rxd),
      .tx_rdy(tx_rdy),
      .tx_en(tx_en),
      .tx_data(tx_data),
      .txd(txd)
  );
endmodule
