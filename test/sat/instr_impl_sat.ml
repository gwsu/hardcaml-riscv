(* requires hardcaml-bloop *)

(*open HardCamlRiscV*)
open Printf 

let solver = ref `mini
let () = 
  let solver_args = [
    "mini", (fun () -> solver := `mini);
    (*"pico", (fun () -> solver := `pico);*)
    "crypto", (fun () -> solver := `crypto);
    "dimacs-mini", (fun () -> solver := `dimacs `mini);
    "dimacs-pico", (fun () -> solver := `dimacs `pico);
    "dimacs-crypto", (fun () -> solver := `dimacs `crypto);
  ] in
  Arg.parse
  [
    "-solver", Arg.Symbol(List.map fst solver_args, 
                         (fun s -> (List.assoc s solver_args)())),
              "select solver"
  ]
  (fun _ -> ())
  "HardCamlRiscV instruction implementation SAT tests"

module B = HardCamlBloop.Gates.Make_comb(HardCamlBloop.Gates.Basic_gates)
(*module B = HardCaml.Signal.Comb*)

module Make(B : HardCaml.Comb.S) = struct

  module Cfg = Config.RV32I_machine

  module Ifs = Interfaces.Make(Cfg)
  module F = Fetch.Make(Ifs)(B)
  module D = Decoder.Make(Ifs)(B)
  module X = Alu.Make(Ifs)(B)
  module M = Mem.Make(Ifs)(B)
  module C = Commit.Make(Ifs)(B)

  let z (_,b) = B.zero b
  let inp (n,b) = B.input n b

  let st_zero = Ifs.Stage.(map z t)
  let sts_zero = Ifs.Stages.(map z t)
  let inp_zero = Ifs.I.(map z t)
  let mi_zero = Ifs.Mi_instr.(map z t)
  let md_zero = Ifs.Mi_data.(map z t)

  let st_inp = Ifs.Stage.(map inp t)
  let inp_inp = Ifs.I.(map inp t)
  let mi_inp = Ifs.Mi_instr.(map inp t)
  let md_inp = Ifs.Mi_data.(map inp t)
  let reduce_st st = Ifs.Stage.(B.reduce B.(|:) @@ B.bits @@ B.concat @@ to_list st)

  let rf ra1 ra2 =
    let open B in
    let regs = 
      Array.to_list @@
      Array.init 32 
        (fun i -> 
          if i=0 then zero 32
          else input ("r"^string_of_int i) 32)
    in
    mux ra1 regs,
    mux ra2 regs

  let build_cpu ~pc ~instr ~rdata = 
    let open Ifs.Stage in
    let open Ifs.Stages in
    
    let fet, mi = F.f ~inp:inp_zero ~comb:sts_zero 
      ~pipe:{ sts_zero with com = { st_zero with pc } }
    in
    
    let dec = D.f 
      ~inp:{ inp_zero with Ifs.I.mi =  { mi_zero with Ifs.Mi_instr.rdata = instr } }
      ~comb:sts_zero 
      ~pipe:{ sts_zero with fet }
    in

    (* model register file as inputs (apart from r0 they are basically like inputs) *)
    let rd n ra = B.(mux2 (ra ==:. 0) (zero 32) (input ("reg_rd"^n) 32)) in
    let rd1, rd2 = rd "1" dec.ra1, rd "2" dec.ra2 in
    let dec = { dec with rd1; rd2 } in

    let alu = X.f ~inp:inp_zero ~comb:sts_zero 
      ~pipe:{ sts_zero with dec }
    in

    let mem, md = M.f 
      ~inp:{ inp_zero with Ifs.I.md = { md_zero with Ifs.Mi_data.rdata = rdata } }
      ~comb:sts_zero 
      ~pipe:{ sts_zero with alu }
    in

    let com = C.f ~inp:inp_zero ~comb:sts_zero 
      ~pipe:{ sts_zero with mem }
    in

    com, rd1, rd2, md

  (*******************************************************************************)

  (* XXX all of this should really be derivable from the instruction specs *)

  let funct3 m = B.select m 14 12
  let funct7 m = B.select m 31 25
  let opcode m = B.select m 6 0

  module I = struct

    type 'a t = 
      {
        rd : 'a;
        rs1 : 'a;
        imm : 'a;
      }

    let make m = 
      let rd = B.input "rd" 5 in
      let rs1 = B.input "rs1" 5 in
      let imm = B.input "imm" 12 in
      let m = B.consti32 32 m in
      let instr = 
        B.concat [
          imm;
          rs1;
          funct3 m;
          rd;
          opcode m;
        ]
      in
      instr, { rd; rs1; imm }

  end

  module I_shift = struct

    type 'a t = 
      {
        rd : 'a;
        rs1 : 'a;
        imm : 'a;
      }

    let make m = 
      let rd = B.input "rd" 5 in
      let rs1 = B.input "rs1" 5 in
      let imm = B.input "imm" 5 in
      let m = B.consti32 32 m in
      let instr = 
        B.concat [
          B.select m 31 25;
          imm;
          rs1;
          funct3 m;
          rd;
          opcode m;
        ]
      in
      instr, { rd; rs1; imm }

  end

  module U = struct

    type 'a t = 
      {
        rd : 'a;
        imm : 'a;
      }

    let make m = 
      let rd = B.input "rd" 5 in
      let imm = B.input "imm" 20 in
      let m = B.consti32 32 m in
      let instr = 
        B.concat [
          imm;
          rd;
          opcode m;
        ]
      in
      instr, { rd; imm }

  end

  module R = struct

    type 'a t = 
      {
        rd : 'a;
        rs1 : 'a;
        rs2 : 'a;
      }

    let make m = 
      let rd = B.input "rd" 5 in
      let rs1 = B.input "rs1" 5 in
      let rs2 = B.input "rs2" 5 in
      let m = B.consti32 32 m in
      let instr = 
        B.concat [
          funct7 m;
          rs2;
          rs1;
          funct3 m;
          rd;
          opcode m;
        ]
      in
      instr, { rd; rs1; rs2 }

  end

  module UJ = struct

    type 'a t = 
      {
        rd : 'a;
        imm : 'a;
      }

    let make m = 
      let rd = B.input "rd" 5 in
      let imm = B.input "imm" 20 in
      let imm' = B.(imm @: gnd) in
      let m = B.consti32 32 m in
      let instr = 
        B.(concat [
          imm'.[20:20];
          imm'.[10:1];
          imm'.[11:11];
          imm'.[19:12];
          rd;
          opcode m;
        ])
      in
      instr, { rd; imm }

  end

  module SB = struct
    
    type 'a t = 
      {
        rs1 : 'a;
        rs2 : 'a;
        imm : 'a;
      }

    let make m = 
      let rs1 = B.input "rs1" 5 in
      let rs2 = B.input "rs2" 5 in
      let imm = B.input "imm" 12 in
      let imm' = B.(imm @: gnd) in
      let m = B.consti32 32 m in
      let instr = 
        B.(concat [
          imm'.[12:12];
          imm'.[10:5];
          rs2;
          rs1;
          funct3 m;
          imm'.[4:1];
          imm'.[11:11];
          opcode m;
        ])
      in
      instr, { rs1; rs2; imm }

  end

  module S = struct

    type 'a t = 
      {
        rs1 : 'a;
        rs2 : 'a;
        imm : 'a; 
      }

    let make m = 
      let rs1 = B.input "rs1" 5 in
      let rs2 = B.input "rs2" 5 in
      let imm = B.input "imm" 12 in
      let m = B.consti32 32 m in
      let instr = 
        B.(concat [
          imm.[11:5];
          rs2;
          rs1;
          funct3 m;
          imm.[4:0];
          opcode m;
        ])
      in
      instr, { rs1; rs2; imm }

  end

  module All = struct
    type 'a t = unit
    let make _ = 
      B.input "instr" 32, ()
  end

  module Csr = struct

    type 'a t = 
      {
        rd : 'a;
        rs1 : 'a;
        csr: 'a;
      }

    let make ?csr ?rs1 m = 
      let rd = B.input "rd" 5 in
      let rs1 = 
        match rs1 with
        | None -> B.input "rs1" 5
        | Some(rs1) -> rs1
      in
      let csr = 
        match csr with
        | None -> B.input "csr" 12 
        | Some(csr) -> csr
      in
      let m = B.consti32 32 m in
      let instr = 
        B.concat [
          csr;
          rs1;
          funct3 m;
          rd;
          opcode m;
        ]
      in
      instr, { rd; rs1; csr }

  end

  open B
  open Ifs.Stage

  type 'a t = 
    {
      instr : B.t;
      rdata : B.t;
      pc : B.t;
      data : 'a;
      st : B.t Ifs.Stage.t;
      rd1 : B.t;
      rd2 : B.t;
      md : B.t Ifs.Mo_data.t;
    }

  let make : 
    Config.T.t -> (Int32.t -> B.t * 'a) -> 'a t
    = fun instr make ->
    let _,match' = List.assoc instr Config.T.mask_match in
    let rdata = input "rdata" 32 in
    let pc = input "pc" 31 @: gnd in
    let instr, data = make match' in
    let st,rd1,rd2, md = build_cpu ~pc ~instr ~rdata in
    { instr; rdata; pc; data; st; rd1; rd2; md }

end

module Core = Make(B)

(*******************************************************************************)

let check ~verbose ~banned x = 
  let open HardCamlBloop.Sat in
  let soln = of_signal ~solver:!solver ~banned (*~verbose:true*) (B.(~:) x) in
  (if verbose then report soln 
   else printf "%s\n" (match soln with `sat _ -> "SAT" | `unsat -> "UNSAT"));
  soln

(*******************************************************************************)

open Core
open Ifs.Stage
open Ifs.Mo_data
open B

let testb show mk instr f = 
  let cost c = HardCamlBloop.(Expr.cost (snd @@ counts Expr.Uset.empty c)) in
  let x = make instr mk in
  let props, banned = f x in
  let all_props = reduce (&:) (List.map fst props) in
  printf "--------------------------------------------------------\n";
  printf "%-.8s[%7i]...%!" (show instr) (cost all_props);
  match check ~verbose:true ~banned all_props with
  | `unsat -> ()
  | `sat _ -> begin
    printf "checking each property\n";
    List.iteri 
      (fun i (p,n) ->
        printf "%-30s: " n;
        ignore @@ check ~verbose:false ~banned p) 
      props
  end

let test ?(no_default_checks=false) mk instr f = 
  let idx = Config.T.Enum_t.from_enum instr in
  testb Config.T.Show_t.show mk instr (fun x -> 
    let props = f x in
    let props_insn =
      if no_default_checks then []
      else
        [
          (~: (msb x.st.insn)), "no trap"; (* trap is not set *) 
          (x.st.insn ==: (sll (one (width x.st.insn)) idx)), "insn decode"; 
        ]
    in
    props @ props_insn, [])

let check_class x z = 
  Ifs.Class_ex.(to_list @@ map3 (fun (n,b) x z -> x ==: z, n) t x.st.iclass z)
  |> List.filter (fun (_,n) -> n <> "f3" && n <> "f7")
  
let zero_class = 
  let module X = Ifs.Class_ex.Make(B) in
  X.zero

(* Register-immediate *)

let imm_props f x = 
  [
    x.st.rdd ==: (f x.rd1 (sresize x.data.I.imm 32)), "rdd = imm op";
    x.st.rad ==: x.data.I.rd, "rad";
    x.st.rwe, "reg write";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    ~: (x.md.req), "no mem req";
  ] 
  @ check_class x { zero_class with Ifs.Class.opi=vdd }

let slt a b = uresize (a <+ b) 32
let sltu a b = uresize (a <: b) 32

let () = List.iter (fun (i,f) -> test I.make i (imm_props f))
  [
    `addi,  (+:);
    `andi,  (&:);
    `ori,   (|:);
    `xori,  (^:);
    `slti,  slt;
    `sltiu, sltu;
  ]

let imm_shift_props f x = 
  [
    x.st.rdd ==: (f x.rd1 x.data.I_shift.imm), "rdd = shift by imm";
    x.st.rad ==: x.data.I_shift.rd, "rad";
    x.st.rwe, "reg write";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    ~: (x.md.req), "no mem req";
  ]
  @ check_class x { zero_class with Ifs.Class.opi=vdd }

let sll_ a b = log_shift sll a b.[4:0]
let srl_ a b = log_shift srl a b.[4:0]
let sra_ a b = log_shift sra a b.[4:0]

let () = List.iter (fun (i,f) -> test I_shift.make i (imm_shift_props f))
  [
    `slli, sll_;
    `srli, srl_;
    `srai, sra_;
  ]

(* Special: lui, auipc *)

let () = test U.make `auipc @@ fun x ->
  [
    x.st.rdd ==: (x.pc +: (x.data.U.imm @: zero 12)), "rdd = pc+imm";
    x.st.rad ==: x.data.U.rd, "rad";
    x.st.rwe, "reg write";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    ~: (x.md.req), "no mem req";
  ]
  @ check_class x { zero_class with Ifs.Class.auipc=vdd }

let () = test U.make `lui @@ fun x ->
  [
    x.st.rdd ==: (x.data.U.imm @: zero 12), "rdd = upper imm";
    x.st.rad ==: x.data.U.rd, "rad";
    x.st.rwe, "reg write";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    ~: (x.md.req), "no mem req";
  ]
  @ check_class x { zero_class with Ifs.Class.lui=vdd }

(* Register-Register *)

let reg_props f x = 
  [
    x.st.rdd ==: (f x.rd1 x.rd2), "rdd = op";
    x.st.rad ==: x.data.R.rd, "rad";
    x.st.rwe, "reg write";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    ~: (x.md.req), "no mem req";
  ]
  @ check_class x { zero_class with Ifs.Class.opr=vdd }

let () = List.iter (fun (i,f) -> test R.make i (reg_props f))
  [
    `add,  (+:);
    `sub,  (-:);
    `and_, (&:);
    `or_,  (|:);
    `xor_, (^:);
    `slt,  slt;
    `sltu, sltu;
    `sll,  sll_;
    `srl,  srl_;
    `sra,  sra_;
  ]

(* Unconditional jump *)

let () = test UJ.make `jal @@ fun x ->
  [
    x.st.pc ==: ((x.pc +: (sresize (x.data.UJ.imm @: gnd) 32)) &:. (-2)), "pc jump"; 
    x.st.rdd ==: (x.pc +:. 4), "rdd = pc+4";
    x.st.rad ==: x.data.UJ.rd, "rad";
    x.st.rwe, "reg write";
    ~: (x.md.req), "no mem req";
  ]
  @ check_class x { zero_class with Ifs.Class.jal=vdd }

let () = test I.make `jalr @@ fun x ->
  [
    x.st.pc ==: (((x.rd1 +: sresize x.data.I.imm 32) &:. (-2))), "pc jump";
    x.st.rdd ==: (x.pc +:. 4), "rdd = pc+4";
    x.st.rad ==: x.data.I.rd, "rad";
    x.st.rwe, "reg write";
    ~: (x.md.req), "no mem req";
  ]
  @ check_class x { zero_class with Ifs.Class.jalr=vdd }

(* Conditional branch *)

let branch_props f x = 
  let taken = f x.Core.rd1 x.rd2 in
  [
    x.st.pc ==: mux2 taken 
      ((x.pc +: sresize (x.data.SB.imm @: gnd) 32) &:. (-2))
      (x.pc +:. 4), "pc = cond set";
    ~: (x.md.req), "no mem req";
    ~: (x.st.rwe), "no reg write";
  ]
  @ check_class x { zero_class with Ifs.Class.bra=vdd }

let () = List.iter (fun (i,f) -> test SB.make i (branch_props f))
  [
    `beq,  (==:);
    `bne,  (<>:);
    `blt,  (<+);
    `bltu, (<:);
    `bge,  (>=+);
    `bgeu, (>=:);
  ]

(* Load and Store *)

let load_props i x =
  let lh = mux2 x.md.addr.[1:1] x.rdata.[31:16] x.rdata.[15:0] in
  let lb = 
    mux x.md.addr.[1:0] 
      [
        x.rdata.[7:0];
        x.rdata.[15:8];
        x.rdata.[23:16];
        x.rdata.[31:24];
      ]
  in
  [
    x.md.addr ==: (x.Core.rd1 +: sresize x.data.I.imm 32), "mem addr";
    x.st.rdd ==: 
        (match i with
        | `lw -> x.rdata
        | `lh -> sresize lh 32
        | `lhu -> uresize lh 32
        | `lb -> sresize lb 32
        | `lbu -> uresize lb 32
        | _ -> failwith ""), "rdd = loaded data";
    x.st.rad ==: x.data.I.rd, "rad";
    x.st.rwe, "reg write";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    x.md.req, "mem req";
    x.md.rw, "mem load";
  ]
  @ check_class x { zero_class with Ifs.Class.ld=vdd }

let () = List.iter (fun i -> test I.make i (load_props i))
  [
    `lw;
    `lh;
    `lhu;
    `lb;
    `lbu;
  ]

let store_props i x = 
  [
    x.md.addr ==: (x.Core.rd1 +: sresize x.data.S.imm 32), "mem addr";
    x.md.wmask ==: 
      (match i with
      | `sw -> const "1111"
      | `sh -> mux2 x.md.addr.[1:1] (const "1100") (const "0011")
      | `sb -> mux x.md.addr.[1:0] (List.map const [ "0001"; "0010"; "0100"; "1000" ])
      | _ -> failwith ""), "mem store mask";
    x.md.wdata ==: 
      (match i with
      | `sw -> x.Core.rd2
      | `sh -> mux2 x.md.addr.[1:1] (x.rd2.[15:0] @: zero 16) (zero 16 @: x.rd2.[15:0])
      | `sb -> mux x.md.addr.[1:0]
                [
                  zero 24 @: x.rd2.[7:0];
                  zero 16 @: x.rd2.[7:0] @: zero  8;
                  zero  8 @: x.rd2.[7:0] @: zero 16;
                             x.rd2.[7:0] @: zero 24;
                ]
      | _ -> failwith ""), "mem store data";
    x.st.pc ==: x.pc +:. 4, "incr pc";
    ~: (x.st.rwe), "no reg write";
    x.md.req, "mem req";
    ~: (x.md.rw), "mem write";
  ]
  @ check_class x { zero_class with Ifs.Class.st=vdd }

let () = List.iter (fun i -> test S.make i (store_props i))
  [
    `sw;
    `sh;
    `sb;
  ]

(* Trap *)

let () = testb (fun _ -> "#trap") All.make `addi (* doesnt matter *) @@ fun x ->
  (* disallow valid instructions, so we force a trap *)
  let insns, csrs = Gencsr.get_full_csrs Config.V.list Ifs.csrs in
  let banned = 
    List.map (fun (mask,mtch) -> ~: ((x.instr &: consti32 32 mask) ^: consti32 32 mtch))
      (insns @ List.concat csrs)
  in
  let props = 
    [
      x.st.iclass.Ifs.Class.trap, "traps";
      ~: (x.st.rwe), "no reg write";
      ~: (x.md.req), "no mem req";
      x.st.insn ==: (sll (one (width x.st.insn)) (width x.st.insn - 1)), "insn=trap";
      (* xxx pc+epc *)
    ]
  in
  props, banned

(* CSRs *)


let all_csrs_mux = 
  let ro_csrs = Gencsr.ro_csrs Ifs.csrs |> List.map (consti 12) in
  let rw_csrs = Gencsr.rw_csrs Ifs.csrs |> List.map (consti 12) in
  let w l = HardCaml.Utils.clog2 (List.length l) in
  let mux l = mux (input "csr_sel" (w l)) l in
  mux (ro_csrs@rw_csrs)

let csrs_insns = 
  [
    `csrrw;
    `csrrc;
    `csrrs;
    `csrrwi;
    `csrrci;
    `csrrsi;
  ]

let ro_csrs_insns = 
  [
    `csrrc;
    `csrrs;
    `csrrci;
    `csrrsi;
  ]

let (==>:) p q = (~: p) |: q
let (<==>:) q p = (p ==>: q) &: (q ==>: p)

let () = List.iter 
    (fun i -> test ~no_default_checks:true (Csr.make ~csr:all_csrs_mux) i @@ fun x -> 
      let traps = x.st.iclass.Ifs.Class.trap in
      let sel g p = (if g then gnd else vdd) |: p in
      let open Ifs.Csr_ctrl in
      [
        traps ==>: (select x.data.Csr.csr 11 10 ==:. 3), "trap on read only";
        (x.st.csr.csr_we_n) ==>: (x.data.Csr.rs1 ==:. 0), "disable csr write";
        (~: traps) ==>:
          ((~: (x.st.csr.csr_write |: 
               x.st.csr.csr_set |: 
               x.st.csr.csr_clr)) ==>:
            (x.data.Csr.rs1 ==:. 0)), "no write ==> rs1=0";
        sel (i <> `csrrw && i <> `csrrwi) 
          ((~: traps) ==>:
            ((x.data.Csr.rs1 ==:. 0) ==>: 
             (~: (x.st.csr.csr_write |: 
                  x.st.csr.csr_set |: 
                  x.st.csr.csr_clr)))), "rs1=0 => no write if ~csrrw[i]";
        sel (i = `csrrw || i = `csrrwi) 
          ((~: traps) ==>: x.st.csr.csr_write), "csrrw[i] always writes";
        sel (i = `csrrs || i = `csrrsi) 
          (((~: traps) &: (x.data.Csr.rs1 <>:. 0)) ==>:
               x.st.csr.csr_set), "csrrs[i] & rs1<>0 ==> set";
        sel (i = `csrrc || i = `csrrci) 
          (((~: traps) &: (x.data.Csr.rs1 <>:. 0)) ==>:
               x.st.csr.csr_clr), "csrrc[i] & rs1<>0 ==> clr";
        (~: traps) ==>: (x.st.rwe), "reg write";
        traps ==>: (~: (x.st.rwe)), "trap ==> no reg write";
        ~: (x.md.req), "no memory access";
        ((ue x.st.csr.csr_write +: 
          ue x.st.csr.csr_set +: 
          ue x.st.csr.csr_clr) <=:. 1), "one of write, set or clear";
        traps ==>: 
          (~: (x.st.csr.csr_write |: x.st.csr.csr_set |: x.st.csr.csr_clr)), 
            "no write on trap";
        x.st.csr.csr_re_n ==>: (x.data.Csr.rd ==:. 0), "no read ==> rd=0";
      ])
    csrs_insns

