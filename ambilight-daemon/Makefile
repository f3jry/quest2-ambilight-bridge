CC = gcc
CFLAGS = -O3 -Wall -Wextra
LIBS = -lm

TARGET = ambilightd

.PHONY: all clean riscv64

all: $(TARGET)

$(TARGET): ambilightd.c stb_image.h
	$(CC) $(CFLAGS) $< $(LIBS) -o $@

riscv64:
	riscv64-linux-gnu-gcc $(CFLAGS) ambilightd.c $(LIBS) -o $(TARGET)-riscv64

clean:
	rm -f $(TARGET) $(TARGET)-riscv64
