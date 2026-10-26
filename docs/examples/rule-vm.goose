// rulevm.goose - a sandbox for untrusted rules: verify, then run.
// Forward-only branches mean termination is a static property; the fixed
// stack and the step budget bound memory and work.
import std;
import os;

const OP_HALT = 0; const OP_PUSH = 1; const OP_ADD = 2; const OP_MUL = 3;
const OP_DUP  = 4; const OP_SWAP = 5; const OP_LT  = 6; const OP_JZ = 7;
const OP_JNZ  = 8; const OP_DROP = 9; const OP_JMP = 10;
const MAX_STACK = 64;
const MAX_CODE = 4096;

struct Program { code: const u8[:], max_depth: i64, budget: i64 }

fn imm(code: u8[:], at: i64) -> i32 {
    return code[at] | ((code[at + 1] as i32) << 8) |
           ((code[at + 2] as i32) << 16) | ((code[at + 3] as i32) << 24);
}

// Static check: every opcode is known, every immediate is in range, every
// branch target is an instruction start inside the code, and no path can
// push more than MAX_STACK values or leave two paths with different depths.
fn verify(code: u8[:], out: Program&, err: u8[>..]&) -> bool {
    if code.len == 0 || code.len > MAX_CODE { format(err, "bad length"); return false; }
    var starts: bool[MAX_CODE] = [false; MAX_CODE];
    var expected: i32[MAX_CODE] = [-2; MAX_CODE];   // -2: no branch targets here
    var targets: i32[MAX_CODE] = [0; MAX_CODE];
    var ntargets = 0;
    var depth = 0;
    var max_depth = 0;
    var pc = 0;
    var reachable = true;
    while pc < code.len {
        starts[pc] = true;
        if !reachable {
            if expected[pc] == -2 { format(err, "unreachable code at ", pc); return false; }
            depth = expected[pc]; reachable = true;
        } else if expected[pc] != -2 && expected[pc] != depth as i32 {
            format(err, "depth mismatch at ", pc); return false;
        }
        let op = code[pc];
        if op == OP_PUSH {
            if pc + 5 > code.len { format(err, "truncated push at ", pc); return false; }
            depth++; if depth > max_depth { max_depth = depth; }
            if depth > MAX_STACK { format(err, "stack overflow at ", pc); return false; }
            pc += 5;
        } else if op == OP_ADD || op == OP_MUL || op == OP_LT {
            if depth < 2 { format(err, "underflow at ", pc); return false; }
            depth--; pc++;
        } else if op == OP_DUP {
            if depth < 1 { format(err, "underflow at ", pc); return false; }
            depth++; if depth > max_depth { max_depth = depth; }
            if depth > MAX_STACK { format(err, "stack overflow at ", pc); return false; }
            pc++;
        } else if op == OP_SWAP {
            if depth < 2 { format(err, "underflow at ", pc); return false; }
            pc++;
        } else if op == OP_DROP {
            if depth < 1 { format(err, "underflow at ", pc); return false; }
            depth--; pc++;
        } else if op == OP_JZ || op == OP_JNZ || op == OP_JMP {
            if pc + 5 > code.len { format(err, "truncated branch at ", pc); return false; }
            if op != OP_JMP && depth < 1 { format(err, "underflow at ", pc); return false; }
            let target = imm(code, pc + 1);
            if target <= pc + 5 || target >= code.len as i32 {
                format(err, "branch target out of range at ", pc); return false;
            }
            if ntargets >= MAX_CODE { format(err, "too many branches"); return false; }
            targets[ntargets] = target; ntargets++;
            let after = if op == OP_JMP { depth } else { depth - 1 };
            if expected[target] != -2 && expected[target] != after as i32 {
                format(err, "inconsistent depth at ", target); return false;
            }
            expected[target] = after as i32;
            depth = after; pc += 5;
            if op == OP_JMP { reachable = false; }
        } else if op == OP_HALT {
            for i in ntargets { if !starts[targets[i]] { format(err, "branch into data at ", targets[i]); return false; } }
            out.code = code; out.max_depth = max_depth; out.budget = code.len * 512; return true;
        } else {
            format(err, "unknown opcode ", op, " at ", pc); return false;
        }
    }
    if !reachable { format(err, "unreachable code at ", pc); return false; }
    format(err, "no halt"); return false;
}

fn run(p: Program) -> i64 {
    var stack: i64[MAX_STACK] = [0; MAX_STACK];
    var sp = 0;
    var pc = 0;
    var steps = 0;
    loop {
        steps++;
        assert(steps <= p.budget);
        let op = p.code[pc];
        if op == OP_HALT { return if sp > 0 { stack[sp - 1] } else { 0 }; }
        if op == OP_PUSH { stack[sp] = imm(p.code, pc + 1); sp++; pc += 5; }
        else if op == OP_ADD { sp--; stack[sp - 1] += stack[sp]; pc++; }
        else if op == OP_MUL { sp--; stack[sp - 1] *= stack[sp]; pc++; }
        else if op == OP_LT  { sp--; stack[sp - 1] = if stack[sp - 1] < stack[sp] { 1 } else { 0 }; pc++; }
        else if op == OP_DUP { stack[sp] = stack[sp - 1]; sp++; pc++; }
        else if op == OP_SWAP { let t = stack[sp - 1]; stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = t; pc++; }
        else if op == OP_DROP { sp--; pc++; }
        else if op == OP_JMP { pc = imm(p.code, pc + 1); }
        else { // JZ / JNZ
            sp--;
            let take = if op == OP_JZ { stack[sp] == 0 } else { stack[sp] != 0 };
            pc = if take { imm(p.code, pc + 1) } else { pc + 5 };
        }
    }
}

fn emit_push(code: u8[>..]&, v: i32) {
    code.push(OP_PUSH);
    for i in 4 { code.push(((v >> (i * 8)) as! u8)); }
}
fn emit_branch(code: u8[>..]&, op: u8, target: i64) {
    code.push(op);
    for i in 4 { code.push(((target >> (i * 8)) as! u8)); }
}

fn main() {
    // max(a, b):  push a; push b; lt; jz else; push a; jmp end; else: push b; end: halt
    var code: u8[>..] = [];
    emit_push(code, 41);
    emit_push(code, 7);
    code.push(OP_LT);
    emit_branch(code, OP_JNZ, 26);
    emit_push(code, 41);
    emit_branch(code, OP_JMP, 31);
    emit_push(code, 7);
    code.push(OP_HALT);

    var err: u8[>..] = [];
    var p = Program { code: "", max_depth: 0, budget: 0 };
    if verify(code, p, err) { print("max(41, 7) = ", run(p)); } else { print("rejected: ", err); }

    // The same VM on hostile input: a branch into the middle of a push.
    var bad: u8[>..] = [];
    emit_push(bad, 1);
    emit_branch(bad, OP_JZ, 12);
    emit_push(bad, 1);
    bad.push(OP_HALT);
    err.clear();
    var q = Program { code: "", max_depth: 0, budget: 0 };
    if verify(bad, q, err) { print("ran hostile program: ", run(q)); } else { print("rejected: ", err); }
}
