#!/bin/bash

# Input file containing original and new names
input_file="original_modules_packages.txt"

# Check if the input file exists
if [ ! -f "$input_file" ]; then
  echo "Error: File $input_file not found."
  exit 1
fi

# Get the target directory from the first argument
if [ -z "$1" ]; then
  echo "Usage: $0 target_directory/"
  exit 1
fi

target_dir="$1"

# Check if the target directory exists
if [ ! -d "$target_dir" ]; then
  echo "Error: Directory $target_dir not found."
  exit 1
fi

# Process each line in the input file
while IFS= read -r line; do
  # Extract original and new names
  original_name=$(echo "$line" | awk '{print $1}')
  new_name=$(echo "$line" | awk '{print $2}')

  # Skip lines that do not contain both names
  if [ -z "$original_name" ] || [ -z "$new_name" ]; then
    continue
  fi

  echo "Replacing $original_name with $new_name in all .sv and .svh files under $target_dir..."

  # Replace the old name with the new name in all .sv and .svh files recursively
  find "$target_dir" -type f \( -name "*.sv" -o -name "*.svh" \) -exec sed -i "s/\b$original_name\b/$new_name/g" {} +

done < "$input_file"

echo "Replacement complete."
