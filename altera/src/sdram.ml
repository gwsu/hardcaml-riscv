module O = interface
    addr[13] ba[2] cas_n[1] 
    cke[1] cs_n[1]
    dqm[2] ras_n[1] we_n[1]
end

module T = interface dq[16] end

module Core = struct

  module P = struct 
    let f s = "mm_" ^ s 
  end
  module IAM = Util.Name_map(P)(Avalon.Master)
  module OAS = Util.Name_map(P)(Avalon.Slave)

  module Q = struct let f s = "io_" ^ s end
  module OD = Util.Name_map(Q)(O)
  module TD = Util.Name_map(Q)(T)

  module I = interface
    clk_clk[1] reset_reset_n[1] 
    mm_burstcount[1] mm_debugaccess[1]
    (mm : IAM)
  end
  module O = interface
    (mm : OAS)
    (sdram : OD)
  end
  module T = TD
end

