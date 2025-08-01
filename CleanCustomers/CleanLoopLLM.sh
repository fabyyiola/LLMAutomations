#!/bin/bash

# === CONFIGURATION ===

INPUT="ClientesSOURCE.csv"             # Input CSV file with raw customer data
API_KEY="GEMINIAPIKEY"                 # Gemini API key
MODEL="gemini-2.5-flash"               # Gemini model to use
MAX_ROWS=5                             # Optional row limit for processing, good to save gemini daily request limits
BATCH_SIZE=5                           # Number of rows to group in each API request

COUNTER=0                              # Row counter
declare -a KEYS=()                     # Stores customer keys to map output later
declare -a PROMPTS=()                  # Stores address prompts to send to Gemini

# === OUTPUT HEADER ===

# Create the output CSV file with clean column names
echo "Key,PostalCode,Municipality,State,Country,CleanAddress" > ClientesCLEANOUTPUT.csv

# === BATCH PROCESSING FUNCTION ===
# This function sends a batch of up to BATCH_SIZE addresses to Gemini and writes the cleaned response to output.

process_batch() {
  local count="${#PROMPTS[@]}"
  if [ "$count" -eq 0 ]; then return; fi  # Skip if no prompts to process

  echo ""
  echo "⏳ Sending batch of $count rows to Gemini..."

  # Build the prompt to send to Gemini, including formatting instructions
  prompt="Please process the following $count addresses. For each one, return a line with these 5 comma-separated fields, in this exact order:

PostalCode,Municipality,State,Country,CleanAddress

Rules:
- Do not include headers or any explanation.
- Just return one clean line per address, in the same order.
- Use only UPPERCASE for municipality, state, and country names.
- Do not use abbreviations like 'TX' or 'USA'. Always return full state and country names in uppercase. For example, 'TEXAS' and 'UNITED STATES'."

  # Add each address to the prompt as a numbered list
  for i in "${!PROMPTS[@]}"; do
    prompt+="
$((i + 1)). ${PROMPTS[i]}"
  done

  # Log the prompt (for traceability)
  echo "📤 Prompt:"
  echo "$prompt"
  echo ""

  # Send prompt to Gemini using curl
  response=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent" \
    -H 'Content-Type: application/json' \
    -H "X-goog-api-key: $API_KEY" \
    -X POST \
    -d "{
      \"contents\": [{
        \"parts\": [{
          \"text\": \"$prompt\"
        }]
      }]
    }")

  # Print raw JSON response from Gemini
  echo "🌐 Raw response:"
  echo "$response"
  echo ""

  # Extract text field containing the result
  parsed=$(echo "$response" | grep -oP '"text":\s*"\K[^"]+')

  # Convert escaped newlines into real newlines
  IFS=$'\n' read -rd '' -a LINES <<< "$(echo "$parsed" | sed 's/\\n/\n/g' | tr -d '\r')"

  # Map each line of Gemini response back to its original customer key
  for i in "${!LINES[@]}"; do
    IFS=',' read -r postal munic state_resp country_resp clean <<< "$(echo "${LINES[i]}" | xargs)"
    echo "${KEYS[i]},$postal,$munic,$state_resp,$country_resp,\"$clean\"" >> ClientesCLEANOUTPUT.csv
  done

  echo "✅ Batch processed: ${#LINES[@]} entries"
  echo "------------------------------------------------------------"

  # Clear the batch arrays for next round
  KEYS=()
  PROMPTS=()
}

# === MAIN LOOP ===
# Reads the input CSV line by line (skipping the header), extracts the address,
# and batches them for processing.

main() {
  while IFS=',' read -r key status name rfc street interior exterior between1 between2 neighborhood postal_code city municipality state country phone email credit balance usage commercial_name stamped
  do
    ((COUNTER++))
    if [ "$COUNTER" -gt "$MAX_ROWS" ]; then break; fi  # Stop if max row count reached

    # Build one-line address by concatenating all relevant fields and removing punctuation
    full_address=$(echo "$name: $street $interior $exterior $between1 $between2 $neighborhood, $postal_code $city $municipality $state $country" | tr -d '",.' | tr -s ' ')

    # Store key and address for batch processing
    KEYS+=("$key")
    PROMPTS+=("$full_address")

    # If batch is full, send to Gemini
    if [ "${#PROMPTS[@]}" -eq "$BATCH_SIZE" ]; then
      process_batch
    fi
  done < <(tail -n +2 "$INPUT")  # Skip CSV header row

  # Process any remaining addresses that didn't complete a full batch
  process_batch
}

# Start the script
main
