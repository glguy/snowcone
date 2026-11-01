#ifndef MYNCURSES_COLORPAIRS_H
#define MYNCURSES_COLORPAIRS_H

/**
 * @brief The color pair for a foreground and background, defining one
 * when needed. Pairs run up to a limit of 200 for each row of the screen,
 * more than its rows can show in colors; past that, the least recently
 * used is redefined.
 *
 * @param fore Foreground color, -1 to COLORS - 1
 * @param back Background color, -1 to COLORS - 1
 * @return Pair number; 0, the terminal's defaults, when none can be had
 */
int colorpairs_get(int fore, int back);

#endif
