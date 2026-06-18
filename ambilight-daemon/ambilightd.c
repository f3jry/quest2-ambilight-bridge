#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <signal.h>

#define FRAME_PATH "/tmp/ambilight-frames/latest.png"
#define DEFAULT_JSON_PATH "/tmp/ambilight-frames/colors.json"
#define DEFAULT_SPI_DEV "/dev/spidev0.0"

#define NUM_LEDS 24
#define TOP_LEDS 8
#define RIGHT_LEDS 4
#define BOTTOM_LEDS 8
#define LEFT_LEDS 4

typedef struct {
    unsigned char r, g, b;
} Color;

int running = 1;

void handle_signal(int sig) {
    (void)sig;
    running = 0;
}

Color get_avg_color(unsigned char *img, int img_w, int img_h, int x, int y, int w, int h) {
    unsigned long long r = 0, g = 0, b = 0;
    int count = 0;
    for (int py = y; py < y + h; py++) {
        for (int px = x; px < x + w; px++) {
            if (px < 0 || px >= img_w || py < 0 || py >= img_h) continue;
            int idx = (py * img_w + px) * 3;
            // Filter out extremely dark pixels (black bars/margins)
            if (img[idx] > 10 || img[idx+1] > 10 || img[idx+2] > 10) {
                r += img[idx];
                g += img[idx+1];
                b += img[idx+2];
                count++;
            }
        }
    }
    // Fallback if all pixels were blacked out
    if (count == 0) {
        for (int py = y; py < y + h; py++) {
            for (int px = x; px < x + w; px++) {
                if (px < 0 || px >= img_w || py < 0 || py >= img_h) continue;
                int idx = (py * img_w + px) * 3;
                r += img[idx];
                g += img[idx+1];
                b += img[idx+2];
                count++;
            }
        }
    }
    Color c = {0, 0, 0};
    if (count > 0) {
        c.r = (unsigned char)(r / count);
        c.g = (unsigned char)(g / count);
        c.b = (unsigned char)(b / count);
    }
    return c;
}

void write_colors_json(Color *leds, int count, const char *path) {
    // Write to a temporary file first, then rename to prevent partial reads by web server
    char temp_path[512];
    snprintf(temp_path, sizeof(temp_path), "%s.tmp", path);

    FILE *f = fopen(temp_path, "w");
    if (!f) return;

    fprintf(f, "{\n  \"leds\": [\n");
    for (int i = 0; i < count; i++) {
        fprintf(f, "    {\"r\": %d, \"g\": %d, \"b\": %d}%s\n", 
                leds[i].r, leds[i].g, leds[i].b, 
                (i == count - 1) ? "" : ",");
    }
    fprintf(f, "  ]\n}\n");
    fclose(f);

    rename(temp_path, path);
}

void write_ws2812b_spi(int spi_fd, Color *leds, int count) {
    // WS2812B expects Green-Red-Blue sequence
    // Using 3MHz SPI frequency: each bit takes 1 SPI byte.
    // High bit: 0xF8 (high for 5/8 of bit time)
    // Low bit:  0xC0 (high for 2/8 of bit time)
    static unsigned char spi_buf[NUM_LEDS * 3 * 8];
    int buf_idx = 0;

    for (int i = 0; i < count; i++) {
        unsigned char channels[3] = { leds[i].g, leds[i].r, leds[i].b };
        for (int c = 0; c < 3; c++) {
            unsigned char val = channels[c];
            for (int b = 7; b >= 0; b--) {
                spi_buf[buf_idx++] = ((val >> b) & 1) ? 0xF8 : 0xC0;
            }
        }
    }

    if (write(spi_fd, spi_buf, buf_idx) < 0) {
        perror("SPI write failed");
    }
    // Wait > 50us for latching
    usleep(100);
}

int main(int argc, char **argv) {
    char *mode = NULL;
    char *output_dest = NULL;

    // Detect environment at compile/runtime
#ifdef __riscv
    mode = "spi";
    output_dest = DEFAULT_SPI_DEV;
#else
    mode = "json";
    output_dest = DEFAULT_JSON_PATH;
#endif

    // Parse options
    int opt;
    while ((opt = getopt(argc, argv, "m:o:h")) != -1) {
        switch (opt) {
            case 'm':
                mode = optarg;
                break;
            case 'o':
                output_dest = optarg;
                break;
            case 'h':
            default:
                fprintf(stderr, "Usage: %s [-m spi|json] [-o output_path_or_device]\n", argv[0]);
                return 1;
        }
    }

    int is_spi = (strcmp(mode, "spi") == 0);
    int spi_fd = -1;

    if (is_spi) {
        spi_fd = open(output_dest, O_RDWR);
        if (spi_fd < 0) {
            perror("Failed to open SPI device");
            fprintf(stderr, "Falling back to JSON mode.\n");
            is_spi = 0;
            output_dest = DEFAULT_JSON_PATH;
        } else {
            printf("Running in SPI mode driving device: %s\n", output_dest);
        }
    }
    
    if (!is_spi) {
        printf("Running in JSON mode outputting to: %s\n", output_dest);
        // Ensure destination folder exists
        char dir_path[512];
        strncpy(dir_path, output_dest, sizeof(dir_path));
        char *last_slash = strrchr(dir_path, '/');
        if (last_slash) {
            *last_slash = '\0';
            struct stat st = {0};
            if (stat(dir_path, &st) == -1) {
                mkdir(dir_path, 0755);
            }
        }
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    struct stat st;
    time_t last_mtime = 0;

    printf("Monitoring frame changes at: %s\n", FRAME_PATH);

    while (running) {
        if (stat(FRAME_PATH, &st) == 0) {
            if (st.st_mtime != last_mtime) {
                int width, height, channels;
                unsigned char *img = stbi_load(FRAME_PATH, &width, &height, &channels, 3);
                if (img) {
                    last_mtime = st.st_mtime;
                    Color top_colors[8];
                    Color right_colors[4];
                    Color bottom_colors[8];
                    Color left_colors[4];

                    int sample_w = 8;
                    int sample_h = 8;

                    // Top: Left to Right
                    for (int i = 0; i < 8; i++) {
                        int x = (i * width) / 8;
                        top_colors[i] = get_avg_color(img, width, height, x, 0, width / 8, sample_h);
                    }
                    // Right: Top to Bottom
                    for (int i = 0; i < 4; i++) {
                        int y = (i * height) / 4;
                        right_colors[i] = get_avg_color(img, width, height, width - sample_w, y, sample_w, height / 4);
                    }
                    // Bottom: Right to Left
                    for (int i = 0; i < 8; i++) {
                        int rev_i = 7 - i;
                        int x = (rev_i * width) / 8;
                        bottom_colors[i] = get_avg_color(img, width, height, x, height - sample_h, width / 8, sample_h);
                    }
                    // Left: Bottom to Top
                    for (int i = 0; i < 4; i++) {
                        int rev_i = 3 - i;
                        int y = (rev_i * height) / 4;
                        left_colors[i] = get_avg_color(img, width, height, 0, y, sample_w, height / 4);
                    }

                    // Map order clockwise starting at Left-Center
                    Color leds[NUM_LEDS];
                    leds[0] = left_colors[2];
                    leds[1] = left_colors[3];
                    for (int i = 0; i < 8; i++) leds[2 + i] = top_colors[i];
                    for (int i = 0; i < 4; i++) leds[10 + i] = right_colors[i];
                    for (int i = 0; i < 8; i++) leds[14 + i] = bottom_colors[i];
                    leds[22] = left_colors[0];
                    leds[23] = left_colors[1];

                    if (is_spi) {
                        write_ws2812b_spi(spi_fd, leds, NUM_LEDS);
                    } else {
                        write_colors_json(leds, NUM_LEDS, output_dest);
                    }

                    stbi_image_free(img);
                }
            }
        }
        usleep(10000); // Check modification status every 10ms
    }

    if (spi_fd >= 0) {
        close(spi_fd);
    }
    printf("Daemon stopped.\n");
    return 0;
}
