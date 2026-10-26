// pool-generations.goose - independent lifetimes in a heapless program:
// a grow-only slot array plus a free list, with generation handles so a
// stale handle is detected instead of reading another object's data.
//
//   pixi run goose build docs/examples/pool-generations.goose
//   ./docs/examples/pool-generations
import std;

struct Slot { gen: u32, live: bool, value: i64 }

fn pool_alloc(slots: Slot[>..]&, free: i64[>..]&, v: i64) -> u64 {
    var idx = 0;
    if free.len > 0 {
        idx = free.pop();
    } else {
        idx = slots.len;
        slots.push(Slot { gen: 1, live: true, value: v });
        return (1 as u64 << 32) | (idx as u64);
    }
    slots[idx].live = true;
    slots[idx].value = v;
    slots[idx].gen++;                     // invalidates older handles
    return ((slots[idx].gen as u64) << 32) | (idx as u64);
}

fn pool_get(slots: Slot[>..]&, h: u64) -> i64, bool {
    let idx = (h & 0xffffffff) as i64;
    let gen = (h >> 32) as u32;
    if idx >= slots.len { return 0, false; }
    let s = slots[idx];
    if !s.live || s.gen != gen { return 0, false; }
    return s.value, true;
}

fn pool_free(slots: Slot[>..]&, free: i64[>..]&, h: u64) -> bool {
    let idx = (h & 0xffffffff) as i64;
    let gen = (h >> 32) as u32;
    if idx >= slots.len { return false; }
    if !slots[idx].live || slots[idx].gen != gen { return false; }
    slots[idx].live = false;
    free.push(idx);
    return true;
}

fn main() {
    var slots: Slot[>..] = [];
    var free: i64[>..] = [];
    var handles: u64[3] = [0; 3];
    for i in 3 { handles[i] = pool_alloc(slots, free, i * 10); }

    let old = handles[1];
    print("freed: ", pool_free(slots, free, handles[1]));
    handles[1] = pool_alloc(slots, free, 99);   // reuses slot 1, new generation

    let v, ok = pool_get(slots, old);
    print("stale handle: ", ok, " value=", v);
    let w, ok2 = pool_get(slots, handles[1]);
    print("fresh handle: ", ok2, " value=", w, " slots=", slots.len, " free=", free.len);
}
