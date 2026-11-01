#include "colorpairs.h"

#include <ncurses.h>

#include <stdint.h>
#include <stdlib.h>

// Pairs a row of the screen may need: a 512-byte line holds about 170
// color changes of 3 bytes
enum
{
    PAIRS_PER_ROW = 200
};

// Pairs 1 to limit, each with its colors, threaded on a list from most to
// least recently used. Index 0 is the list's head: pair 0 is the
// terminal's defaults and never defined here. A screen redraws in full,
// so the pairs it uses are always more recent than any redefined.
//
// The limit also bounds the tree in which ncurses keeps the pairs
// defined. Where tsearch doesn't balance it (macOS), colors arriving in
// sorted order make it a list, and each pair defined takes time in
// proportion to the pairs there are.
//
// A hash table of pair numbers finds the pair for two colors. It has at
// least twice as many slots as pairs, so it is never more than half full;
// 0 is an empty slot. Collisions take the next slot, and a removal moves
// later entries back over the gap, so no slot is ever marked deleted.
static struct
{
    int count;     // COLOR_PAIRS
    int limit;     // pairs to use; grows with the screen, never shrinks
    int used;      // pairs defined so far, from 1
    int shift;     // 64 - log2(slots)
    uint32_t mask; // slots - 1
    int* slots;
    int* fore;
    int* back;
    int* prev;
    int* next;
    int failed; // couldn't allocate: always pair 0
} t;

static uint32_t home(int const fore, int const back)
{
    uint64_t const key = (uint64_t)(uint32_t)fore << 32 | (uint32_t)back;
    return (uint32_t)((key * UINT64_C(0x9e3779b97f4a7c15)) >> t.shift);
}

static int setup(void)
{
    if (t.slots != NULL)
    {
        return 1;
    }
    if (t.failed || COLOR_PAIRS < 2)
    {
        return 0;
    }

    int bits = 1;
    while (((size_t)1 << bits) < (size_t)COLOR_PAIRS * 2)
    {
        bits++;
    }
    size_t const slots = (size_t)1 << bits;
    size_t const count = COLOR_PAIRS;

    t.slots = calloc(slots, sizeof *t.slots);
    t.fore = malloc(count * sizeof *t.fore);
    t.back = malloc(count * sizeof *t.back);
    t.prev = malloc(count * sizeof *t.prev);
    t.next = malloc(count * sizeof *t.next);
    if (!t.slots || !t.fore || !t.back || !t.prev || !t.next)
    {
        free(t.slots);
        free(t.fore);
        free(t.back);
        free(t.prev);
        free(t.next);
        t.slots = NULL;
        t.failed = 1;
        return 0;
    }

    t.count = COLOR_PAIRS;
    t.limit = 0;
    t.used = 0;
    t.shift = 64 - bits;
    t.mask = (uint32_t)(slots - 1);
    t.prev[0] = t.next[0] = 0;
    return 1;
}

// Up to the screen's needs, within the pairs the terminal has
static void update_limit(void)
{
    long const wanted = (long)PAIRS_PER_ROW * (LINES > 0 ? LINES : 1);
    int const limit = wanted < t.count - 1 ? (int)wanted : t.count - 1;
    if (limit > t.limit)
    {
        t.limit = limit;
    }
}

static void unlink_pair(int const pair)
{
    t.next[t.prev[pair]] = t.next[pair];
    t.prev[t.next[pair]] = t.prev[pair];
}

// Most recently used: first on the list
static void push_front(int const pair)
{
    t.prev[pair] = 0;
    t.next[pair] = t.next[0];
    t.prev[t.next[0]] = pair;
    t.next[0] = pair;
}

// Least recently used: last on the list
static void push_back(int const pair)
{
    t.next[pair] = 0;
    t.prev[pair] = t.prev[0];
    t.next[t.prev[0]] = pair;
    t.prev[0] = pair;
}

// The slot holding the pair for these colors, or the empty slot that
// would hold it
static uint32_t find(int const fore, int const back)
{
    uint32_t i = home(fore, back);
    for (;;)
    {
        int const pair = t.slots[i];
        if (pair == 0 || (t.fore[pair] == fore && t.back[pair] == back))
        {
            return i;
        }
        i = (i + 1) & t.mask;
    }
}

static void insert(int const pair, int const fore, int const back)
{
    t.fore[pair] = fore;
    t.back[pair] = back;
    t.slots[find(fore, back)] = pair;
}

static void remove_pair(int const pair)
{
    uint32_t gap = find(t.fore[pair], t.back[pair]);
    // Each later entry, up to an empty slot, moves back into the gap
    // unless it would land before its home slot
    for (uint32_t i = (gap + 1) & t.mask; t.slots[i] != 0; i = (i + 1) & t.mask)
    {
        int const moved = t.slots[i];
        uint32_t const from_home = (i - home(t.fore[moved], t.back[moved])) & t.mask;
        uint32_t const from_gap = (i - gap) & t.mask;
        if (from_home >= from_gap)
        {
            t.slots[gap] = moved;
            gap = i;
        }
    }
    t.slots[gap] = 0;
}

int colorpairs_get(int const fore, int const back)
{
    if (!setup())
    {
        return 0;
    }

    int const found = t.slots[find(fore, back)];
    if (found != 0)
    {
        unlink_pair(found);
        push_front(found);
        return found;
    }

    update_limit();
    int pair;
    int const fresh = t.used < t.limit;
    if (fresh)
    {
        pair = ++t.used;
    }
    else
    {
        pair = t.prev[0];
        unlink_pair(pair);
        remove_pair(pair);
    }

    if (ERR == init_extended_pair(pair, fore, back))
    {
        // the pair keeps what it had
        if (fresh)
        {
            t.used--;
        }
        else
        {
            insert(pair, t.fore[pair], t.back[pair]);
            push_back(pair);
        }
        return 0;
    }

    insert(pair, fore, back);
    push_front(pair);
    return pair;
}
