#!/usr/bin/env python3
import time
import random
from board import SCL, SDA
import busio
from PIL import Image, ImageDraw
import adafruit_ssd1306

# Initialize I2C and OLED
i2c = busio.I2C(SCL, SDA)
oled = adafruit_ssd1306.SSD1306_I2C(128, 64, i2c)

SCALE = 2
COLS = 128 // SCALE
ROWS = 64 // SCALE

def create_random_grid():
    return [[random.choice([0, 1]) for _ in range(COLS)] for _ in range(ROWS)]

grid = create_random_grid()

def count_neighbors(g, x, y):
    count = 0
    for i in range(-1, 2):
        for j in range(-1, 2):
            if i == 0 and j == 0: continue
            col = (x + i + COLS) % COLS
            row = (y + j + ROWS) % ROWS
            count += g[row][col]
    return count

# Track previous states to detect if the simulation gets stuck
history = []
generation = 0
MAX_GENERATIONS = 300  # Force a reset after this many steps, just in case

while True:
    image = Image.new("1", (128, 64))
    draw = ImageDraw.Draw(image)

    new_grid = [[0 for _ in range(COLS)] for _ in range(ROWS)]

    alive_count = 0
    for y in range(ROWS):
        for x in range(COLS):
            # Draw current cell
            if grid[y][x] == 1:
                draw.rectangle((x*SCALE, y*SCALE, x*SCALE+(SCALE-1), y*SCALE+(SCALE-1)), fill=255)
                alive_count += 1

            # Compute next generation
            neighbors = count_neighbors(grid, x, y)
            if grid[y][x] == 1 and (neighbors == 2 or neighbors == 3):
                new_grid[y][x] = 1
            elif grid[y][x] == 0 and neighbors == 3:
                new_grid[y][x] = 1

    oled.image(image)
    oled.show()
    generation += 1

    # === STAGNATION DETECTION ===
    is_stuck = False

    if alive_count == 0:
        is_stuck = True  # Everything died
    elif new_grid in history:
        is_stuck = True  # Stuck in a static pattern or oscillator loop
    elif generation > MAX_GENERATIONS:
        is_stuck = True  # Lived too long, force refresh for variety

    if is_stuck:
        # Don't wipe the screen! Just drop a "meteor" of new life
        start_x = random.randint(0, COLS - 15)
        start_y = random.randint(0, ROWS - 15)

        for my in range(start_y, start_y + 15):
            for mx in range(start_x, start_x + 15):
                # 40% chance of life inside the meteor zone
                grid[my][mx] = 1 if random.random() < 0.4 else 0

        history = []
        generation = 0
    else:
        grid = new_grid
        history.append(grid)
        # Remember the last 6 generations (catches up to 6-step oscillator loops)
        if len(history) > 6:
            history.pop(0)
