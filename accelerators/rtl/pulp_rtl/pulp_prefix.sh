#!/bin/bash

# File to store the list of original module/package names
output_file="original_modules_packages.txt"
> "$output_file"  # Clear the file if it exists

# Regex patterns to match module and package declarations
module_pattern='^(\s*module\s+)([a-zA-Z_][a-zA-Z0-9_]*)'
package_pattern='^(\s*package\s+)([a-zA-Z_][a-zA-Z0-9_]*)'

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

# Process each .sv and .svh file in the target directory
find "$target_dir" -type f \( -name "*.sv" -o -name "*.svh" \) | while read -r file; do

  echo "Processing $file..."

  # Temporary file to store the modified content
  temp_file="${file}.tmp"
  > "$temp_file"

  while IFS= read -r line; do
    if [[ $line =~ $module_pattern ]]; then
      original_name="${BASH_REMATCH[2]}"
      modified_name="pulp_${original_name}"
      echo "$line" | sed "s/\b$original_name\b/$modified_name/" >> "$temp_file"
      echo "$original_name $modified_name" >> "$output_file"
    elif [[ $line =~ $package_pattern ]]; then
      original_name="${BASH_REMATCH[2]}"
      modified_name="pulp_${original_name}"
      echo "$line" | sed "s/\b$original_name\b/$modified_name/" >> "$temp_file"
      echo "$original_name $modified_name" >> "$output_file"
    else
      echo "$line" >> "$temp_file"
    fi
  done < "$file"

  # Replace the original file with the modified file
  mv "$temp_file" "$file"

done

echo "Processing complete. Original names saved in $output_file."
