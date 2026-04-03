#!/usr/bin/env python3
import time
import random
import psutil
from board import SCL, SDA
import busio
from PIL import Image, ImageDraw
import adafruit_ssd1306

# Initialize I2C and OLED
i2c = busio.I2C(SCL, SDA)
oled = adafruit_ssd1306.SSD1306_I2C(128, 64, i2c)

WIDTH = 128
HEIGHT = 64
CENTER_X = WIDTH // 2
CENTER_Y = HEIGHT // 2
NUM_STARS = 60

class Star:
    def __init__(self):
        self.reset()
        # Randomize initial Z so they don't all spawn at the same distance
        self.z = random.uniform(0.1, 2.0)

    def reset(self):
        # Pick a random point in 2D space, but treat it as 3D far away
        self.x = random.uniform(-WIDTH, WIDTH)
        self.y = random.uniform(-HEIGHT, HEIGHT)
        self.z = 2.0 # Farthest distance
        self.pz = self.z # Previous z for drawing motion blur/lines

stars = [Star() for _ in range(NUM_STARS)]

# Set a time to periodically check the CPU (checking every frame is too intensive)
last_cpu_check = 0
current_speed = 0.05

while True:
    # Check CPU every 1 second to update the speed
    if time.time() - last_cpu_check > 1.0:
        cpu_load = psutil.cpu_percent()
        
        # Map CPU load (0% to 100%) to a speed value.
        # e.g., 0% load = 0.02 speed (slow cruising)
        # 100% load = 0.20 speed (warp speed)
        min_speed = 0.02
        max_speed = 0.25
        
        current_speed = min_speed + (cpu_load / 100.0) * (max_speed - min_speed)
        last_cpu_check = time.time()

    # Create blank image for drawing
    image = Image.new("1", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)

    for star in stars:
        # Update Z distance (moving the star closer to the camera)
        star.pz = star.z
        star.z -= current_speed

        # If the star has passed the camera, reset it to the background
        if star.z <= 0:
            star.reset()
            continue

        # Map 3D coordinates to 2D screen coordinates
        # Current position
        sx = int((star.x / star.z) + CENTER_X)
        sy = int((star.y / star.z) + CENTER_Y)

        # Previous position (to draw a line/motion blur based on speed)
        px = int((star.x / star.pz) + CENTER_X)
        py = int((star.y / star.pz) + CENTER_Y)

        # If the star goes off screen, reset it
        if sx < 0 or sx >= WIDTH or sy < 0 or sy >= HEIGHT:
            star.reset()
            continue
        
        # Draw the star as a line from its previous position to its current position
        # This creates a cool "warp speed" stretching effect when moving fast
        draw.line((px, py, sx, sy), fill=255)

    # Display image on OLED
    oled.image(image)
    oled.show()
    
    # Small sleep to prevent maxing out the CPU just to draw the screen
    time.sleep(0.01)
