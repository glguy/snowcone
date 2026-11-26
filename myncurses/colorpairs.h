// Color pairs for foreground and background colors, defined on demand

#ifndef MYNCURSES_COLORPAIRS_H
#define MYNCURSES_COLORPAIRS_H

/**
 * @brief The color pair for a foreground and background, defining one
 * when needed. Pairs run up to a limit of 200 for each row of the screen;
 * past that, the least recently used is redefined, recoloring any cell
 * still drawn with it, unless the frame being drawn has used every pair:
 * then the limit grows, up to COLOR_PAIRS - 1.
 *
 * @param fore Foreground color, -1 to COLORS - 1 (not checked here)
 * @param back Background color, -1 to COLORS - 1 (not checked here)
 * @return Pair number; 0, the terminal's defaults, when none can be had:
 * the terminal has no pairs, the table can't be allocated, or ncurses
 * refuses the colors
 */
int colorpairs_get(int fore, int back);

/**
 * @brief Start a new frame: what was drawn is on the terminal, and the
 * next redraw replaces it, so its pairs may be redefined. Called whenever
 * the virtual screen is shown.
 */
void colorpairs_next_frame(void);

#endif
