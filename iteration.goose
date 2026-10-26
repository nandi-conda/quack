// iteration.goose - request-scoped work with state that outlives a request.
//
// A long-running loop handles one synthetic request per iteration:
//   * per-request line and normalization buffers live on data stacks and are
//     freed when the loop body / handle() call ends;
//   * a fixed-capacity ring of the most recent results lives in a `reusable`
//     pool, so the server's state has a hard bound and freed slots are reused.
//
// Run in-process:  goose iteration.goose
// Build:           goose build iteration.goose && ./iteration

import std;

const RING = 6;

struct Entry {
    path: u8[..28],     // inline, so Entry is fixed-size and can live in a pool
    status: i32,
    bytes: i64,
    hash: u32,
}

// The only long-lived dynamic state: a bounded pool of recent requests.
reusable var recent: Entry[>..] = [];

fn line_hash(xs: u8[:]) -> u32 {
    var h: u32 = 2166136261;
    for x in xs { h = (h ^ x) * 16777619; }
    return h;
}

// Parses one request line and returns a flat record. The scratch buffer is a
// local data-stack value: it is gone when this function returns.
fn handle(line: u8[:]) -> Entry {
    var normalized: u8[>..] = [];
    let parts = split(line, ' ');
    var e = Entry { path: "", status: 0, bytes: 0, hash: 0 };
    if parts.len >= 4 {
        e.path.append(parts[1]);
        let status, ok_status = parse_int(parts[2]);
        let bytes, ok_bytes = parse_int(parts[3]);
        if ok_status { e.status = status as i32; }
        if ok_bytes { e.bytes = bytes; }
        format(normalized, parts[0], " ", parts[1]);
        e.hash = line_hash(normalized);
    }
    return e;
}

fn main() {
    print("Goose heap-less request loop: ", RING, "-entry ring in a reusable pool");

    var slots: i64[RING] = [-1; RING];   // ring position -> pool slot
    var head = 0;
    var count = 0;

    for i in 24 {
        // Per-request scratch, rebuilt and freed on every pass.
        var line: u8[>..] = [];
        format(line, "GET /api/items/", i % 7, " ", 200, " ", 512 + i * 37);

        let e = handle(line[..]);

        // Keep only the newest RING entries: free the oldest slot, then reuse
        // a free slot for the new entry.
        if count == RING {
            recent.free(slots[head]);
        } else {
            count++;
        }
        let slot = recent.alloc_index(e);
        slots[head] = slot;
        head = (head + 1) % RING;

        if i % 4 == 3 {
            print("req ", i, ": ", line, " -> hash=", e.hash,
                  " ring=", count, "/", RING, " pool slots=", recent.len);
        }
    }

    print("-- newest first --");
    for k in count {
        let pos = (head - 1 - k + RING) % RING;
        let e = recent[slots[pos]];
        print("  ", e.path, " status=", e.status, " bytes=", e.bytes, " hash=", e.hash);
    }
    print("pool slots=", recent.len, " (capacity ", RING, ", no growth)");
}
