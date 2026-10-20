# Worst setup path into each pipeline register group (sourced after link + constraints).
# Output is grep'ed by summarize: lines "GROUP <name>" followed by a report_checks.
proc grp {name pats} {
  set c {}
  foreach pat $pats { set c [concat $c [get_cells -quiet $pat]] }
  if {[llength $c] == 0} { puts "GROUP $name: none"; return }
  puts "GROUP $name"
  report_checks -path_delay max -to [get_pins -of_objects $c -filter "direction == input"] -digits 3
}
grp pc        {pc_*}
grp instr_id  {instr_id* pc_id* bubble_id*}
grp id_ex_op  {rd1_ex* rd2_ex*}
grp id_ex_ctl {valid_ex* reg_write_ex* imm_ex* pc_ex* instr_ex* alu_op_ex* opcode_ex* funct3_ex*}
grp regfile   {regs*}
grp mul       {u_mul.*}
grp div       {u_div.*}
grp dcache    {u_dcache.*}
grp csr       {u_priv.*}
grp lsu       {lsu_st* mul_wait* div_wait* paddr_q*}
foreach port {dmem_addr[*] dmem_we dmem_re imem_addr[*]} {
  puts "GROUP out:$port"
  report_checks -path_delay max -to [get_ports $port] -digits 3
}
