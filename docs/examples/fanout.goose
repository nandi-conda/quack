// fanout.goose - a fixed worker pool with bounded queues.
// Threads need a real C compiler: goose build fanout.goose
import std;
import os;

struct Job  { id: i32, kind: i32, a: i64, b: i64 }
struct Done { id: i32, value: i64 }

fn apply(j: Job) -> i64 {
    if j.kind == 0 { return j.a + j.b; }
    if j.kind == 1 { return j.a * j.b; }
    var h: u64 = 14695981039346656037;
    var x = j.a;
    for i in 8 { h = (h ^ (x as! u64)) * 1099511628211; x >>= 8; }
    return h as! i64;
}

thread_fn worker() {
    loop {
        let j = qget<Job>();
        guard j.id >= 0 else { break; }        // one quit message per worker
        let d = Done { id: j.id, value: apply(j) };
        // qput never blocks: a full queue means "not now". Retry, or the
        // result is lost.
        while !qput(d) { sleep_ms(1); }
    }
}

fn main() {
    let n = max(1, hardware_threads());
    qlimit<Job>(1024);         // 1024 queued jobs, then qput says no
    qlimit<Done>(1024);        // and the same bound on results
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(worker)); }

    var submitted = 0;
    var refused = 0;
    for i in 200000 {
        let job = Job { id: i as i32, kind: (i % 3) as i32, a: i, b: 7 };
        if qput(job) { submitted++; } else { refused++; }
    }

    var sum: i64 = 0;
    for i in submitted { let r = qget<Done>(); sum += r.value; }

    for i in n { qput(Job { id: -1, kind: 0, a: 0, b: 0 }); }
    for id in ids { thread_wait(id); }
    print("workers=", n, " submitted=", submitted, " refused=", refused, " checksum=", sum);
}
