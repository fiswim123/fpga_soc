//*******************************
  //  AXI - AXIv4
  //*******************************

  `ifndef AXI_ADDR_WIDTH
    `define AXI_ADDR_WIDTH        32
  `endif

  `ifndef AXI_DATA_WIDTH
    `define AXI_DATA_WIDTH        32
  `endif

  `ifndef AXI_ALEN_WIDTH
    `define AXI_ALEN_WIDTH        8
  `endif

  `ifndef AXI_ASIZE_WIDTH
    `define AXI_ASIZE_WIDTH       3
  `endif

  `ifndef AXI_MAX_OUTSTD_RD
    `define AXI_MAX_OUTSTD_RD     2
  `endif

  `ifndef AXI_MAX_OUTSTD_WR
    `define AXI_MAX_OUTSTD_WR     2
  `endif

  `ifndef AXI_USER_RESP_WIDTH
    `define AXI_USER_RESP_WIDTH   1
  `endif

  `ifndef AXI_USER_REQ_WIDTH
    `define AXI_USER_REQ_WIDTH    1
  `endif

  `ifndef AXI_USER_DATA_WIDTH
    `define AXI_USER_DATA_WIDTH   1
  `endif

  `ifndef AXI_TXN_ID_WIDTH
    `define AXI_TXN_ID_WIDTH      8
  `endif

  //*******************************
  //  AXIS - AXIv4 Stream
  //*******************************

  `ifndef AXIS_DATA_WIDTH
    `define AXIS_DATA_WIDTH       8
  `endif

  `ifndef AXIS_TXN_ID_WIDTH
    `define AXIS_TXN_ID_WIDTH     8
  `endif

  `ifndef AXIS_TDST_WIDTH
    `define AXIS_TDST_WIDTH       1
  `endif

  `ifndef AXIS_TUSER_WIDTH
    `define AXIS_TUSER_WIDTH      1
  `endif