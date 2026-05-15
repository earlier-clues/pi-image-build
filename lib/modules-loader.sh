#!/bin/bash
# Payload modules loader: parse, validate, and emit. Runs host-side only.
# Public API: parse_modules_list, resolve_module, validate_schemas, emit_runner.
# Helper API (used inside validate_schemas): require, optional.
LIB_API_VERSION=1

# parse_modules_list <list-file>
#   Reads <list-file>, strips comments (#…) and blank lines, prints one
#   module name per line in declared order. Aborts with exit 2 if the
#   file contains a duplicate name.
parse_modules_list() {
    local list_file="$1"
    local -a names=()
    local line name

    [[ -f "$list_file" ]] || {
        echo "error: modules.list not found: $list_file" >&2
        return 2
    }

    while IFS= read -r line; do
        # Strip leading/trailing whitespace and comments.
        line="${line%\#*}"
        line="${line#"${line%%[! 	]*}"}"
        line="${line%"${line##*[! 	]}"}"
        [[ -n "$line" ]] || continue
        names+=("$line")
    done < "$list_file"

    # Check for duplicates using uniq -d.
    local -a duplicates=()
    while IFS= read -r dup; do
        duplicates+=("$dup")
    done < <(printf '%s\n' "${names[@]}" | sort | uniq -d)
    if (( ${#duplicates[@]} > 0 )); then
        for dup in "${duplicates[@]}"; do
            echo "error: duplicate module in modules.list: $dup" >&2
        done
        return 2
    fi

    # Output in original order.
    printf '%s\n' "${names[@]}"
}

# resolve_module <name> <payload-dir> <repo-modules-dir>
#   Prints the absolute path to <name>'s module dir on stdout.
#   Checks <payload-dir>/modules/<name>/ first (payload-local shadows),
#   then <repo-modules-dir>/<name>/. Aborts with exit 2 if neither exists.
resolve_module() {
    local name="$1"
    local payload_dir="$2"
    local repo_modules_dir="$3"

    local payload_module_dir="$payload_dir/modules/$name"
    local repo_module_dir="$repo_modules_dir/$name"

    if [[ -d "$payload_module_dir" ]]; then
        echo "$payload_module_dir"
        return 0
    fi

    if [[ -d "$repo_module_dir" ]]; then
        echo "$repo_module_dir"
        return 0
    fi

    echo "error: module not found: $name (checked $payload_module_dir and $repo_module_dir)" >&2
    return 2
}

# validate_schemas <module-dir>...
#   Sources each module's schema.sh in a subshell with `require` and
#   `optional` bound to validator implementations. Collects errors
#   across ALL schemas (does not exit on first failure). On any error,
#   prints the full collected list to stderr and aborts with exit 2.
#   On success, prints the resolved env-var declarations (one
#   `export NAME=VALUE` per line) to stdout.
validate_schemas() {
    local -a module_dirs=("$@")
    local err_file exports_file
    local module_dir module_name
    local -i exit_code=0

    # Create temp files for error and exports collection.
    err_file="$(mktemp)"
    exports_file="$(mktemp)"
    trap "rm -f '$err_file' '$exports_file'" RETURN

    # Validate each schema in a subshell so side-effects (like `set +a`)
    # don't escape and confuse the parent.
    for module_dir in "${module_dirs[@]}"; do
        module_name="$(basename "$module_dir")"
        local schema_file="$module_dir/schema.sh"

        [[ -f "$schema_file" ]] || {
            echo "error: module $module_name: schema.sh not found" >&2
            return 2
        }

        # Source the schema in a subshell with require/optional bound.
        # These functions append to the tempfiles, not stdout.
        (
            set -euo pipefail

            # Export paths so the schema's require/optional can use them.
            export __LOADER_ERR_FILE="$err_file"
            export __LOADER_EXPORTS_FILE="$exports_file"
            readonly CURRENT_MODULE="$module_name"

            # Define require and optional helpers used by the schema.
            require() {
                local var_name="$1"
                local var_value="${!var_name:-}"

                if [[ -z "$var_value" ]]; then
                    printf "module %s: required var %s is unset\n" "$CURRENT_MODULE" "$var_name" >> "$__LOADER_ERR_FILE"
                else
                    printf "export %s=%q\n" "$var_name" "$var_value" >> "$__LOADER_EXPORTS_FILE"
                fi
            }

            optional() {
                local var_name="$1"
                local default_value=""
                local var_value="${!var_name:-}"

                # Parse "default=VALUE" syntax.
                if [[ "$2" == default=* ]]; then
                    default_value="${2#default=}"
                fi

                if [[ -z "$var_value" ]]; then
                    var_value="$default_value"
                    export "$var_name=$var_value"
                fi

                printf "export %s=%q\n" "$var_name" "$var_value" >> "$__LOADER_EXPORTS_FILE"
            }

            # Source the schema. The schema calls require() and optional()
            # which write to the tempfiles.
            # shellcheck source=/dev/null
            source "$schema_file"
        ) || {
            exit_code=$?
        }
    done

    # Check if any errors were collected.
    if [[ -s "$err_file" ]]; then
        cat "$err_file" >&2
        return 2
    fi

    # Output all collected exports (variables that passed validation).
    [[ -f "$exports_file" ]] && cat "$exports_file" || true
}

# emit_runner <out-path> <module-chroot-path>...
#   Writes a synthetic bash script to <out-path> that sources each
#   <module-chroot-path>/module.sh in declared order. Each source line
#   is preceded by an `export MODULE_DIR=...` so the module can reference
#   its assets without depending on ${BASH_SOURCE}.
emit_runner() {
    local out_path="$1"
    shift
    local -a module_chroot_paths=("$@")
    local module_path module_name

    {
        echo "#!/bin/bash"
        echo "# Synthetic module runner — generated by lib/modules-loader.sh."
        local -a module_names=()
        for module_path in "${module_chroot_paths[@]}"; do
            module_names+=("$(basename "$module_path")")
        done
        printf "# Modules: %s\n" "$(IFS=,; echo "${module_names[*]}")"
        echo "set -euo pipefail"
        echo "export MODULES_DIR=\"\${MODULES_DIR:-/tmp/pibuild/modules}\""
        echo "export PAYLOAD_DIR=\"\${PAYLOAD_DIR:-/tmp/pibuild/payload}\""
        echo "export LIB_DIR=\"\${LIB_DIR:-/tmp/pibuild/lib}\""
        echo ""

        for module_path in "${module_chroot_paths[@]}"; do
            module_name="$(basename "$module_path")"
            echo "echo \"==> module: $module_name\""
            echo "export MODULE_DIR=\"$module_path\""
            echo "source \"\$MODULE_DIR/module.sh\""
            echo ""
        done
    } > "$out_path"
}
