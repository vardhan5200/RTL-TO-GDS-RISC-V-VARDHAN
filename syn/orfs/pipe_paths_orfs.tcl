# Worst setup path (clock group only) into each register group of core_top.
proc grp {name pats} {
  set c {}
  foreach pat $pats { set c [concat $c [get_cells -hierarchical -quiet $pat]] }
  if {[llength $c] == 0} { puts "GROUP $name: none"; return }
  puts "GROUP $name ([llength $c] cells)"
  report_checks -path_delay max -path_group core_clock \
      -to [get_pins -of_objects $c -filter "direction == input"] -digits 3
}
grp pc        {pc\[*}
grp if_id     {instr_id* pc_id* bubble_id* fault_id* fcause_id*}
grp id_ex_op  {rd1_ex* rd2_ex* imm_ex* pc_ex*}
grp id_ex_ctl {valid_ex* reg_write_ex* instr_ex* alu_op_ex* funct3_ex* rd_ex* wr_ex* is_*_ex* *_ex\$*}
grp regfile   {regs\[*}
grp mul       {u_mul/*}
grp div       {u_div/*}
grp dcache    {u_dcache/*}
grp csr       {u_priv/*}
grp lsu       {lsu_st* mul_wait* div_wait* paddr_q* mmu_fault*}
grp icache    {*u_icache/*}
