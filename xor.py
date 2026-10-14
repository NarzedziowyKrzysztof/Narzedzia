#!/usr/bin/env python3
import sys

if len(sys.argv) != 4:
    print(f"Użycie: {sys.argv[0]} PLIK_WYJŚCIOWY KLUCZ PLIK_WEJŚCIOWY")
    sys.exit(1)

output_file, key, input_file = sys.argv[1:]
key = key.encode("utf-8")

if not key:
    sys.exit("Klucz nie może być pusty.")

with open(input_file, "rb") as f:
    data = f.read()

result = bytes(byte ^ key[i % len(key)] for i, byte in enumerate(data))

with open(output_file, "wb") as f:
    f.write(result)
	
	
# Użycie
# python3 xor.py plik_zakodowany.bin "moj-klucz" plik.txt

# Odszyfrowanie wykonasz tą samą komendą, zamieniając pliki wejściowy i wyjściowy:
# python3 xor.py odzyskany.txt "moj-klucz" plik_zakodowany.bin
