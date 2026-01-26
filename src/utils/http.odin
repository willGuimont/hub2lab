#+vet
package utils

import "core:c/libc"
import "core:fmt"
import "core:strconv"
import "core:strings"

Response :: struct {
	status_code: int,
	body:        string,
}

foreign import libc_system "system:c"

foreign libc_system {
	popen :: proc(command: cstring, type: cstring) -> ^libc.FILE ---
	pclose :: proc(stream: ^libc.FILE) -> i32 ---
}

execute_curl :: proc(args: []string) -> (Response, bool) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "curl -s -i ")
	for arg in args {
		escaped, allocated := strings.replace_all(arg, "'", "'\\''")

		strings.write_string(&builder, "'")
		strings.write_string(&builder, escaped)
		strings.write_string(&builder, "' ")

		if allocated {
			delete(escaped)
		}
	}

	cmd_str := strings.to_string(builder)
	c_cmd := strings.clone_to_cstring(cmd_str)
	defer delete(c_cmd)

	mode := "r"
	c_mode := strings.clone_to_cstring(mode)
	defer delete(c_mode)

	f := popen(c_cmd, c_mode)
	if f == nil {
		return Response{}, false
	}
	defer pclose(f)

	output_builder := strings.builder_make()
	defer strings.builder_destroy(&output_builder)

	buf: [1024]byte
	for {
		n := libc.fread(&buf[0], 1, 1024, f)
		if n <= 0 {break}
		strings.write_bytes(&output_builder, buf[:n])
	}

	full_output := strings.to_string(output_builder)

	header_end := strings.index(full_output, "\r\n\r\n")
	if header_end == -1 {
		header_end = strings.index(full_output, "\n\n")
	}

	status := 0
	body := ""

	if header_end != -1 {
		header_part := full_output[:header_end]
		lines := strings.split(header_part, "\n")
		defer delete(lines)

		if len(lines) > 0 {
			status_line := lines[0]
			parts := strings.split(status_line, " ")
			defer delete(parts)
			if len(parts) >= 2 {
				status = 0
				res, ok := strconv.parse_int(parts[1])
				if ok {
					status = res
				}
			}
		}

		sep_len := 0
		if strings.contains(full_output, "\r\n\r\n") {
			sep_len = 4
		} else {
			sep_len = 2
		}

		body = full_output[header_end + sep_len:]
	} else {
		body = full_output
	}

	return Response{status_code = status, body = strings.clone(body)}, true
}

get :: proc(url: string, headers: map[string]string) -> (Response, bool) {
	args := make([dynamic]string)
	defer delete(args)

	append(&args, "-X", "GET", url)

	for k, v in headers {
		append(&args, "-H")
		header_str := fmt.tprintf("%s: %s", k, v)
		append(&args, header_str)
	}

	return execute_curl(args[:])
}

post :: proc(url: string, headers: map[string]string, body: string) -> (Response, bool) {
	args := make([dynamic]string)
	defer delete(args)

	append(&args, "-X", "POST", url)

	for k, v in headers {
		append(&args, "-H")
		header_str := fmt.tprintf("%s: %s", k, v)
		append(&args, header_str)
	}

	append(&args, "-d")
	append(&args, body)

	return execute_curl(args[:])
}
