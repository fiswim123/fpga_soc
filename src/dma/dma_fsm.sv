/**
 * File              : dma_fsm.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 10.06.2022
 * Last Modified Date: 13.06.2022
 */
`include "inc/amba_axi.svh"
`include "inc/dma_pkg.svh"
module dma_fsm
  import amba_axi_pkg::*;
  import dma_utils_pkg::*;
(
  input                                     clk,
  input                                     rst,
  // From/To CSRs
  input   s_dma_control_t                   dma_ctrl_i,
  input   s_dma_desc_t [`DMA_NUM_DESC-1:0]  dma_desc_i,
  output  s_dma_status_t                    dma_stats_o,
  // From/To AXI I/F
  input                                     axi_pend_txn_i,
  input   s_dma_error_t                     axi_txn_err_i,
  output  s_dma_error_t                     dma_error_o,
  output  logic                             clear_dma_o,
  output  logic                             dma_active_o,
  // To/From streamers
  output  s_dma_str_in_t                    dma_stream_rd_o,
  input   s_dma_str_out_t                   dma_stream_rd_i,
  output  s_dma_str_in_t                    dma_stream_wr_o,
  input   s_dma_str_out_t                   dma_stream_wr_i
);
  dma_st_t cur_st_ff, next_st;
  logic [`DMA_NUM_DESC-1:0] rd_desc_done_ff, next_rd_desc_done;
  logic [`DMA_NUM_DESC-1:0] wr_desc_done_ff, next_wr_desc_done;

  // 新增寄存器定义（和 rd_desc_done_ff 同级）
idx_desc_t rd_idx_ff, next_rd_idx;
idx_desc_t wr_idx_ff, next_wr_idx;

  logic pending_desc; // Gets set when there are pending descriptors to process
  logic pending_rd_desc, pending_wr_desc;
  logic abort_ff;

  function automatic logic check_cfg();
    logic [`DMA_NUM_DESC-1:0] valid_desc;

    valid_desc = '0;

    for (int i=0; i<`DMA_NUM_DESC; i++) begin
      if (dma_desc_i[i].enable) begin
        valid_desc[i] = (|dma_desc_i[i].num_bytes);
      end
    end
    return |valid_desc;
  endfunction

  always_comb begin : fsm_dma_ctrl
    next_st = DMA_ST_IDLE;
    pending_desc = pending_rd_desc || pending_wr_desc;

    case (cur_st_ff)
      DMA_ST_IDLE: begin
        if (dma_ctrl_i.go) begin
          next_st = DMA_ST_CFG;
        end
      end
      DMA_ST_CFG: begin
        if (~dma_ctrl_i.abort_req && check_cfg()) begin
          next_st = DMA_ST_RUN;
        end
        else begin
          next_st = DMA_ST_DONE;
        end
      end
      DMA_ST_RUN: begin
        if (pending_desc || axi_pend_txn_i) begin
          next_st = DMA_ST_RUN;
        end
        else begin
          next_st = DMA_ST_DONE;
        end
      end
      DMA_ST_DONE: begin
        if (dma_ctrl_i.go) begin
          next_st = DMA_ST_DONE;
        end
      end
    endcase
  end : fsm_dma_ctrl

  // rd_streamer 块内修改
always_comb begin : rd_streamer
  dma_stream_rd_o   = s_dma_str_in_t'('0);
  next_rd_desc_done = rd_desc_done_ff;
  pending_rd_desc   = 1'b0;
  dma_active_o      = (cur_st_ff == DMA_ST_RUN);
  next_rd_idx       = rd_idx_ff;

  if (cur_st_ff == DMA_ST_RUN) begin
    for (int i=0; i<`DMA_NUM_DESC; i++) begin
      if (dma_desc_i[i].enable && (|dma_desc_i[i].num_bytes) && (~rd_desc_done_ff[i])) begin
        dma_stream_rd_o.idx   = i;
        dma_stream_rd_o.valid = ~abort_ff;
        next_rd_idx           = i;   // 锁存当前发出去的idx
        break;
      end
    end

    if (dma_stream_rd_i.done) begin
      next_rd_desc_done[rd_idx_ff] = 1'b1; // 用锁存idx
    end

    pending_rd_desc = dma_stream_rd_o.valid;
  end

  if (cur_st_ff == DMA_ST_DONE) begin
    next_rd_desc_done = '0;
  end
end : rd_streamer

  // wr_streamer 块内修改
always_comb begin : wr_streamer
  dma_stream_wr_o   = s_dma_str_in_t'('0);
  next_wr_desc_done = wr_desc_done_ff;
  pending_wr_desc   = 1'b0;
  next_wr_idx       = wr_idx_ff;

  if (cur_st_ff == DMA_ST_RUN) begin
    for (int i=0; i<`DMA_NUM_DESC; i++) begin
      if (dma_desc_i[i].enable && (|dma_desc_i[i].num_bytes) && (~wr_desc_done_ff[i])) begin
        dma_stream_wr_o.idx   = i;
        dma_stream_wr_o.valid = ~abort_ff;
        next_wr_idx           = i;   // 锁存当前发出去的idx
        break;
      end
    end

    if (dma_stream_wr_i.done) begin
      next_wr_desc_done[wr_idx_ff] = 1'b1; // 用锁存idx
    end

    pending_wr_desc = dma_stream_wr_o.valid;
  end

  if (cur_st_ff == DMA_ST_DONE) begin
    next_wr_desc_done = '0;
  end
end : wr_streamer

  always_comb begin : dma_status
    dma_error_o = s_dma_error_t'('0);

    if (axi_txn_err_i.valid) begin
      dma_error_o.addr     = axi_txn_err_i.addr;
      dma_error_o.type_err = DMA_ERR_OPE;
      dma_error_o.src      = axi_txn_err_i.src;
      dma_error_o.valid    = 1'b1;
    end
    dma_stats_o.error = axi_txn_err_i.valid;
    dma_stats_o.done  = (cur_st_ff == DMA_ST_DONE);
    clear_dma_o       = (cur_st_ff == DMA_ST_DONE) && (next_st == DMA_ST_IDLE);
  end : dma_status

  // 时序块里加寄存器更新
always_ff @(posedge clk) begin
  if (rst) begin
    cur_st_ff       <= dma_st_t'('0);
    rd_desc_done_ff <= '0;
    wr_desc_done_ff <= '0;
    rd_idx_ff       <= '0;
    wr_idx_ff       <= '0;
    abort_ff        <= '0;
  end else begin
    cur_st_ff       <= next_st;
    rd_desc_done_ff <= next_rd_desc_done;
    wr_desc_done_ff <= next_wr_desc_done;
    rd_idx_ff       <= next_rd_idx;
    wr_idx_ff       <= next_wr_idx;
    abort_ff        <= dma_ctrl_i.abort_req;
  end
end
endmodule
