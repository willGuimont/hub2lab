#+vet
package config

import "core:os"
import "core:strings"

load_env :: proc(filepath: string) -> bool {
	data, ok := os.read_entire_file(filepath)
	if !ok {
		return false
	}
	defer delete(data)

	it := string(data)
	for line in strings.split_iterator(&it, "\n") {
		trimmed_line := strings.trim_space(line)
		if len(trimmed_line) == 0 || strings.has_prefix(trimmed_line, "#") {
			continue
		}

		parts := strings.split(trimmed_line, "=")
		if len(parts) >= 2 {
			key := strings.trim_space(parts[0])
			val := strings.trim_space(strings.join(parts[1:], "="))

			if len(val) >= 2 &&
			   ((val[0] == '"' && val[len(val) - 1] == '"') ||
					   (val[0] == '\'' && val[len(val) - 1] == '\'')) {
				val = val[1:len(val) - 1]
			}

			os.set_env(key, val)
		}
		delete(parts)
	}
	return true
}
