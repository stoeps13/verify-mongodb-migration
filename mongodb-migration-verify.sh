#!/bin/bash

# MongoDB Migration Verification Minimal Shell Script
#
# This script operates in two phases without requiring jq or Python:
# 1. COLLECT: Counts documents in MongoDB 5 before migration and saves to a file
# 2. VERIFY: Compares MongoDB 7 document counts against the saved file after migration
#
# Usage:
#   - Collect phase: ./mongodb-migration-verify.sh collect output_file.txt
#   - Verify phase:  ./mongodb-migration-verify.sh verify input_file.txt

# Configuration
MONGO_HOST=${MONGO_HOST:-"mongo7-0.mongo7.connections.svc.cluster.local"}
MONGO_AUTH=${MONGO_AUTH:-"--authenticationDatabase '$external' --authenticationMechanism MONGODB-X509"}
MONGO_URI=${MONGO_URI:-"mongodb://$MONGO_HOST:27017"}
EXCLUDED_DBS=${EXCLUDED_DBS:-"admin config local"}
MONGO_CERT=${MONGO_CERT:-"/etc/mongodb/x509/user_admin.pem"}
MONGO_CA=${MONGO_CA:-"/etc/mongodb/x509/mongo-CA-cert.crt"}
MONGO_TLS=${MONGO_TLS:-"true"}

# Set up MongoDB connection options
MONGO_OPTS=""

if [ "$MONGO_TLS" = "true" ]; then
  MONGO_OPTS="--tls"
  [ -n "$MONGO_CERT" ] && MONGO_OPTS="$MONGO_OPTS --tlsCertificateKeyFile=$MONGO_CERT"
  [ -n "$MONGO_CA" ] && MONGO_OPTS="$MONGO_OPTS --tlsCAFile=$MONGO_CA"
fi

# Function to check if a database should be excluded
is_excluded_db() {
  local db_name=$1
  for excluded in $EXCLUDED_DBS; do
    if [ "$db_name" = "$excluded" ]; then
      return 0
    fi
  done
  return 1
}

# Function to format numbers with commas
format_number() {
  printf "%'d" $1
}

# Function to get MongoDB version
get_mongo_version() {
  local version=$(mongosh $MONGO_OPTS --host $MONGO_HOST --$MONGO_AUTH --quiet --eval "db.version()")
  echo $version
}

# Function to collect document counts
collect_counts() {
  local output_file=$1

  echo "MongoDB Document Count Collection"
  echo "================================"
  echo "MongoDB URI: $MONGO_HOST"
  echo "Excluded Databases: $EXCLUDED_DBS"
  echo "Output File: $output_file"
  echo "================================"
  echo

  # Get MongoDB version
  local mongo_version=$(get_mongo_version)
  echo "MongoDB Version: $mongo_version"

  # Start with an empty output file and write header
  echo "# MongoDB Count File - Version: $mongo_version - Date: $(date)" > "$output_file"
  echo "# Format: database.collection|count" >> "$output_file"

  # Get list of databases (one per line)
  local dbs=$(mongosh $MONGO_OPTS --host $MONGO_HOST --$MONGO_AUTH --quiet --eval "db.adminCommand('listDatabases').databases.map(d => d.name).join('\n')")

  # Process each database
  for db in $dbs; do
    # Skip excluded databases
    if is_excluded_db "$db"; then
      echo "Skipping excluded database: $db"
      continue
    fi

    echo -e "\nProcessing database: $db"

    # Get collections in this database (one per line)
    local collections=$(mongosh $MONGO_OPTS $MONGO_AUTH $MONGO_URI/$db --quiet --eval "db.getCollectionNames().join('\n')")

    # Process each collection
    for coll in $collections; do
      # Count documents
      local count=$(mongosh $MONGO_OPTS $MONGO_AUTH $MONGO_URI/$db --quiet --eval "db.${coll}.countDocuments({})")

      # Handle error in count
      if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "  Error counting $db.$coll, setting to 0"
        count=0
      fi

      # Format and display count
      local formatted_count=$(format_number $count)
      echo "  $db.$coll: $formatted_count documents"

      # Add to output file (using pipe as separator)
      echo "$db.$coll|$count" >> "$output_file"
    done
  done

  echo -e "\nCounts saved to: $output_file"
  return 0
}

# Function to verify document counts
verify_counts() {
  local input_file=$1

  echo "MongoDB Migration Verification"
  echo "=============================="
  echo "MongoDB URI: $MONGO_URI"
  echo "Input File: $input_file"
  echo "Excluded Databases: $EXCLUDED_DBS"
  echo "=============================="
  echo

  # Check if input file exists
  if [ ! -f "$input_file" ]; then
    echo "Error: Input file '$input_file' not found!"
    return 1
  fi

  # Get current MongoDB version
  local current_version=$(get_mongo_version)

  # Get saved MongoDB version from file header
  local saved_version=$(grep "^# MongoDB Count File - Version:" "$input_file" | sed 's/^# MongoDB Count File - Version: \([^ ]*\).*/\1/')
  local saved_date=$(grep "^# MongoDB Count File - Version:" "$input_file" | sed 's/^.* - Date: \(.*\)$/\1/')

  echo "Loaded counts from MongoDB $saved_version taken at $saved_date"
  echo "Current MongoDB version: $current_version"
  echo

  # Create output file
  local timestamp=$(date +"%Y%m%d%H%M%S")
  local output_file="migration-verification-$timestamp.txt"
  echo "# MongoDB Verification Results" > "$output_file"
  echo "# Previous Version: $saved_version" >> "$output_file"
  echo "# Current Version: $current_version" >> "$output_file"
  echo "# Verification Date: $(date)" >> "$output_file"

  # Initialize counters
  local total_dbs=0
  local matched_dbs=0
  local total_colls=0
  local matched_colls=0

  # Arrays for tracking issues
  declare -A db_collections
  declare -A db_matched
  declare -A mismatched_collections
  declare -A missing_collections

  # Get list of current databases
  local current_dbs=$(mongosh $MONGO_OPTS $MONGO_AUTH $MONGO_URI --quiet --eval "db.adminCommand('listDatabases').databases.map(d => d.name).join('\n')")

  # First pass: build a list of databases and track collections
  while IFS="|" read -r collection_name count || [ -n "$collection_name" ]; do
    # Skip commented lines and empty lines
    [[ "$collection_name" =~ ^#.*$ || -z "$collection_name" ]] && continue

    # Split database and collection
    local db=$(echo "$collection_name" | cut -d. -f1)

    # Skip excluded databases
    if is_excluded_db "$db"; then
      continue
    fi

    # Track unique databases
    if [[ -z "${db_collections[$db]}" ]]; then
      db_collections[$db]=1
      db_matched[$db]=1
      total_dbs=$((total_dbs + 1))
    else
      db_collections[$db]=$((db_collections[$db] + 1))
    fi
  done < "$input_file"

  # Check if databases exist in current MongoDB
  for db in "${!db_collections[@]}"; do
    local db_exists=0
    for current_db in $current_dbs; do
      if [ "$db" = "$current_db" ]; then
        db_exists=1
        break
      fi
    done

    if [ $db_exists -eq 0 ]; then
      echo "❌ Database '$db' does not exist in current MongoDB!"
      echo "MISSING_DB: $db" >> "$output_file"
      db_matched[$db]=0
    fi
  done

  # Second pass: verify each collection
  while IFS="|" read -r collection_name saved_count || [ -n "$collection_name" ]; do
    # Skip commented lines and empty lines
    [[ "$collection_name" =~ ^#.*$ || -z "$collection_name" ]] && continue

    # Split database and collection
    local db=$(echo "$collection_name" | cut -d. -f1)
    local coll=$(echo "$collection_name" | cut -d. -f2-)

    # Skip excluded databases
    if is_excluded_db "$db"; then
      continue
    fi

    # Check if database exists
    if [ "${db_matched[$db]}" -eq 0 ]; then
      continue
    fi

    echo "Verifying: $collection_name"
    total_colls=$((total_colls + 1))

    # Get current count
    local current_count=$(mongosh $MONGO_OPTS $MONGO_AUTH $MONGO_URI/$db --quiet --eval "db['${coll}'].countDocuments({})")

    # Handle error in count (collection might not exist)
    if [[ ! "$current_count" =~ ^[0-9]+$ ]]; then
      echo "  ❌ Collection '$collection_name' not found in current MongoDB"
      missing_collections["$collection_name"]=1
      db_matched[$db]=0
      echo "MISSING_COLLECTION: $collection_name" >> "$output_file"
      continue
    fi

    # Compare counts
    if [ "$saved_count" -eq "$current_count" ]; then
      echo "  ✅ $collection_name: $(format_number $saved_count) → $(format_number $current_count)"
      matched_colls=$((matched_colls + 1))
      echo "MATCH: $collection_name|$saved_count|$current_count" >> "$output_file"
    else
      local diff=$((current_count - saved_count))
      local diff_sign=$([ $diff -ge 0 ] && echo "+" || echo "")
      echo "  ❌ $collection_name: $(format_number $saved_count) → $(format_number $current_count) ($diff_sign$diff)"
      mismatched_collections["$collection_name"]="$saved_count|$current_count|$diff"
      db_matched[$db]=0
      echo "MISMATCH: $collection_name|$saved_count|$current_count|$diff" >> "$output_file"
    fi
  done < "$input_file"

  # Count matched databases
  for db in "${!db_matched[@]}"; do
    if [ "${db_matched[$db]}" -eq 1 ]; then
      matched_dbs=$((matched_dbs + 1))
    fi
  done

  # Print summary
  echo
  echo "=============================="
  echo "Migration Verification Summary"
  echo "=============================="
  echo "MongoDB Version: $saved_version → $current_version"
  echo "Databases: $matched_dbs/$total_dbs matched"
  echo "Collections: $matched_colls/$total_colls matched"

  # Print mismatched collections
  if [ ${#mismatched_collections[@]} -gt 0 ]; then
    echo
    echo "Mismatched Collections:"
    echo "----------------------"

    for coll in "${!mismatched_collections[@]}"; do
      IFS="|" read -r saved current diff <<< "${mismatched_collections[$coll]}"
      local diff_sign=$([ $diff -ge 0 ] && echo "+" || echo "")
      echo "$coll: $(format_number $saved) → $(format_number $current) ($diff_sign$diff)"
    done
  fi

  # Print missing collections
  if [ ${#missing_collections[@]} -gt 0 ]; then
    echo
    echo "Missing Collections:"
    echo "-------------------"
    for coll in "${!missing_collections[@]}"; do
      echo "- $coll"
    done
  fi

  # Overall success/failure
  echo
  echo "=============================="
  if [ $matched_colls -eq $total_colls ]; then
    echo "✅ MIGRATION VERIFIED SUCCESSFULLY"
    echo "RESULT: SUCCESS" >> "$output_file"
    local result=0
  else
    echo "❌ MIGRATION VERIFICATION FAILED"
    echo "   $((total_colls - matched_colls)) collection(s) have issues"
    echo "RESULT: FAILURE" >> "$output_file"
    local result=1
  fi
  echo "=============================="

  echo
  echo "Detailed results saved to: $output_file"

  return $result
}

# Main script
if [ $# -lt 2 ]; then
  echo "Error: Insufficient arguments"
  echo "Usage:"
  echo "  - Collect phase: $0 collect output_file.txt"
  echo "  - Verify phase:  $0 verify input_file.txt"
  exit 1
fi

MODE=$1
FILE=$2

case $MODE in
  collect)
    collect_counts "$FILE"
    exit $?
    ;;
  verify)
    verify_counts "$FILE"
    exit $?
    ;;
  *)
    echo "Error: Invalid mode '$MODE'. Use either 'collect' or 'verify'."
    exit 1
    ;;
esac
