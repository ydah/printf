# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module LibCStringFunctions
        private

        def emit_libc_string_memory_call(call, context: nil)
          case call.fetch(:function_name)
          when "atoi" then emit_atoi_call(call, context:)
          when "isalnum", "isalpha", "isdigit", "isspace", "tolower", "toupper" then emit_ctype_call(call, context:)
          when "memcmp" then emit_memcmp_call(call, context:)
          when "memchr" then emit_memchr_call(call, context:)
          when "strcat" then emit_strcat_call(call, nil, context:)
          when "strchr" then emit_strchr_call(call, reverse: false, context:)
          when "strcmp" then emit_strcmp_call(call, nil, context:)
          when "strcpy" then emit_strcpy_call(call, nil, context:)
          when "strcspn" then emit_strspan_call(call, stop_on_match: true, context:)
          when "strdup" then emit_strdup_call(call, context:)
          when "strncat" then emit_strcat_call(call, parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(2), context:)
          when "strncpy" then emit_strcpy_call(call, parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(2), context:)
          when "strpbrk" then emit_strpbrk_call(call, context:)
          when "strrchr" then emit_strchr_call(call, reverse: true, context:)
          when "strspn" then emit_strspan_call(call, stop_on_match: false, context:)
          when "strtol" then emit_strtol_call(call, context:)
          else emit_strcmp_call(call, parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(2), context:)
          end
        end

        def emit_ctype_call(call, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          value = scalar_value(arguments.fetch(0).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          function = call.fetch(:function_name)
          expression = case function
                       when "isdigit" then "((#{value}) >= '0' && (#{value}) <= '9')"
                       when "isalpha" then "(((#{value}) >= 'A' && (#{value}) <= 'Z') || ((#{value}) >= 'a' && (#{value}) <= 'z'))"
                       when "isalnum" then "(((#{value}) >= '0' && (#{value}) <= '9') || ((#{value}) >= 'A' && (#{value}) <= 'Z') || ((#{value}) >= 'a' && (#{value}) <= 'z'))"
                       when "isspace" then "((#{value}) == ' ' || (#{value}) == '\\t' || (#{value}) == '\\n' || (#{value}) == '\\v' || (#{value}) == '\\f' || (#{value}) == '\\r')"
                       when "tolower" then "(((#{value}) >= 'A' && (#{value}) <= 'Z') ? ((#{value}) + 32) : (#{value}))"
                       when "toupper" then "(((#{value}) >= 'a' && (#{value}) <= 'z') ? ((#{value}) - 32) : (#{value}))"
                       end
          if function.start_with?("is")
            ["    #{target} = (#{expression}) ? 1u : 0u;"]
          else
            ["    #{target} = (unsigned int)(unsigned char)(#{expression});"]
          end
        end

        def emit_atoi_call(call, context:)
          strtol_call = call.merge(
            function_name: "strtol",
            raw_arguments: "#{parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(0).fetch(:type)} #{parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(0).fetch(:value)}, ptr null, i32 10",
            return_type: "i64"
          )
          lines = emit_strtol_call(strtol_call, context:, target_override: context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination)), target_bits: 32)
          lines
        end

        def emit_memcmp_call(call, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          left = memory_address(arguments.fetch(0).fetch(:value), context:)
          right = memory_address(arguments.fetch(1).fetch(:value), context:)
          length = scalar_value(arguments.fetch(2).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          prefix = next_memory_intrinsic_prefix
          [
            "    {",
            "        long long #{prefix}_left = (long long)(#{left.offset});",
            "        long long #{prefix}_right = (long long)(#{right.offset});",
            "        int #{prefix}_len = (int)(#{length});",
            *dynamic_valid_address_lines(left),
            *dynamic_valid_address_lines(right),
            "        if (#{prefix}_left < 0 || #{prefix}_right < 0 || #{prefix}_len < 0 || #{prefix}_left + #{prefix}_len > #{left.limit} || #{prefix}_right + #{prefix}_len > #{right.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: memcmp out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        #{target} = (unsigned long long)(int)pf_llvm_bytes_compare(#{left.memory}, (int)#{prefix}_left, #{right.memory}, (int)#{prefix}_right, #{prefix}_len);",
            "    }"
          ]
        end

        def emit_memchr_call(call, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          source = memory_address(arguments.fetch(0).fetch(:value), context:)
          byte = scalar_value(arguments.fetch(1).fetch(:value), context:)
          length = scalar_value(arguments.fetch(2).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          pointer_map = context ? context.fetch(:pointers) : pointers
          pointer_map[call.fetch(:destination)] = EncodedPointer.new(value: target) if call.fetch(:destination)
          prefix = next_memory_intrinsic_prefix
          [
            "    {",
            "        unsigned long long #{prefix}_base_encoded = #{encoded_pointer_value(arguments.fetch(0).fetch(:value), context:)};",
            "        long long #{prefix}_base = (long long)(#{source.offset});",
            "        long long #{prefix}_len = (long long)(#{length});",
            "        long long #{prefix}_i = 0;",
            "        unsigned char #{prefix}_needle = (unsigned char)(#{byte});",
            *dynamic_valid_address_lines(source),
            "        #{target} = 0ull;",
            "        if (#{prefix}_base < 0 || #{prefix}_len < 0 || #{prefix}_base + #{prefix}_len > #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: memchr out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        for (#{prefix}_i = 0; #{prefix}_i < #{prefix}_len; #{prefix}_i++) {",
            "            if (#{source.memory}[#{prefix}_base + #{prefix}_i] == #{prefix}_needle) {",
            "                #{target} = #{encoded_string_result(prefix, "#{prefix}_base + #{prefix}_i")};",
            "                break;",
            "            }",
            "        }",
            "    }"
          ]
        end

        def emit_strchr_call(call, reverse:, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          source = memory_address(arguments.fetch(0).fetch(:value), context:)
          byte = scalar_value(arguments.fetch(1).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          pointer_map = context ? context.fetch(:pointers) : pointers
          pointer_map[call.fetch(:destination)] = EncodedPointer.new(value: target) if call.fetch(:destination)
          prefix = next_memory_intrinsic_prefix
          break_after_match = reverse ? [] : ["                break;"]
          [
            "    {",
            "        unsigned long long #{prefix}_base_encoded = #{encoded_pointer_value(arguments.fetch(0).fetch(:value), context:)};",
            "        long long #{prefix}_base = (long long)(#{source.offset});",
            "        long long #{prefix}_i = 0;",
            "        unsigned char #{prefix}_needle = (unsigned char)(#{byte});",
            *dynamic_valid_address_lines(source),
            "        #{target} = 0ull;",
            "        if (#{prefix}_base < 0 || #{prefix}_base >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_base + #{prefix}_i < #{source.limit}) {",
            "            unsigned char #{prefix}_ch = #{source.memory}[#{prefix}_base + #{prefix}_i];",
            "            if (#{prefix}_ch == #{prefix}_needle) {",
            "                #{target} = #{encoded_string_result(prefix, "#{prefix}_base + #{prefix}_i")};",
            *break_after_match,
            "            }",
            "            if (#{prefix}_ch == 0u) break;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_base + #{prefix}_i >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "    }"
          ]
        end

        def emit_strspan_call(call, stop_on_match:, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          source = memory_address(arguments.fetch(0).fetch(:value), context:)
          charset = memory_address(arguments.fetch(1).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          prefix = next_memory_intrinsic_prefix
          stop_condition = stop_on_match ? "#{prefix}_matched != 0" : "#{prefix}_matched == 0"
          [
            "    {",
            "        long long #{prefix}_base = (long long)(#{source.offset});",
            "        long long #{prefix}_set = (long long)(#{charset.offset});",
            "        long long #{prefix}_i = 0;",
            *dynamic_valid_address_lines(source),
            *dynamic_valid_address_lines(charset),
            "        #{target} = 0ull;",
            "        if (#{prefix}_base < 0 || #{prefix}_set < 0 || #{prefix}_base >= #{source.limit} || #{prefix}_set >= #{charset.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_base + #{prefix}_i < #{source.limit}) {",
            "            unsigned char #{prefix}_ch = #{source.memory}[#{prefix}_base + #{prefix}_i];",
            "            long long #{prefix}_j = 0;",
            "            int #{prefix}_matched = 0;",
            "            if (#{prefix}_ch == 0u) break;",
            "            while (#{prefix}_set + #{prefix}_j < #{charset.limit}) {",
            "                unsigned char #{prefix}_set_ch = #{charset.memory}[#{prefix}_set + #{prefix}_j];",
            "                if (#{prefix}_set_ch == 0u) break;",
            "                if (#{prefix}_set_ch == #{prefix}_ch) {",
            "                    #{prefix}_matched = 1;",
            "                    break;",
            "                }",
            "                #{prefix}_j++;",
            "            }",
            "            if (#{prefix}_set + #{prefix}_j >= #{charset.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} charset missing null terminator\\n\");",
            "                PF_ABORT();",
            "            }",
            "            if (#{stop_condition}) break;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_base + #{prefix}_i >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "        #{target} = (unsigned long long)#{prefix}_i;",
            "    }"
          ]
        end

        def emit_strpbrk_call(call, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          source = memory_address(arguments.fetch(0).fetch(:value), context:)
          charset = memory_address(arguments.fetch(1).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          pointer_map = context ? context.fetch(:pointers) : pointers
          pointer_map[call.fetch(:destination)] = EncodedPointer.new(value: target) if call.fetch(:destination)
          prefix = next_memory_intrinsic_prefix
          [
            "    {",
            "        unsigned long long #{prefix}_base_encoded = #{encoded_pointer_value(arguments.fetch(0).fetch(:value), context:)};",
            "        long long #{prefix}_base = (long long)(#{source.offset});",
            "        long long #{prefix}_set = (long long)(#{charset.offset});",
            "        long long #{prefix}_i = 0;",
            *dynamic_valid_address_lines(source),
            *dynamic_valid_address_lines(charset),
            "        #{target} = 0ull;",
            "        if (#{prefix}_base < 0 || #{prefix}_set < 0 || #{prefix}_base >= #{source.limit} || #{prefix}_set >= #{charset.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strpbrk pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_base + #{prefix}_i < #{source.limit}) {",
            "            unsigned char #{prefix}_ch = #{source.memory}[#{prefix}_base + #{prefix}_i];",
            "            long long #{prefix}_j = 0;",
            "            if (#{prefix}_ch == 0u) break;",
            "            while (#{prefix}_set + #{prefix}_j < #{charset.limit}) {",
            "                unsigned char #{prefix}_set_ch = #{charset.memory}[#{prefix}_set + #{prefix}_j];",
            "                if (#{prefix}_set_ch == 0u) break;",
            "                if (#{prefix}_set_ch == #{prefix}_ch) {",
            "                    #{target} = #{encoded_string_result(prefix, "#{prefix}_base + #{prefix}_i")};",
            "                    break;",
            "                }",
            "                #{prefix}_j++;",
            "            }",
            "            if (#{prefix}_set + #{prefix}_j >= #{charset.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: strpbrk charset missing null terminator\\n\");",
            "                PF_ABORT();",
            "            }",
            "            if (#{target} != 0ull) break;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_base + #{prefix}_i >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strpbrk missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "    }"
          ]
        end

        def emit_strcpy_call(call, limit_argument, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          destination = memory_address(arguments.fetch(0).fetch(:value), context:)
          ensure_writable_address!(destination)
          source = memory_address(arguments.fetch(1).fetch(:value), context:)
          prefix = next_memory_intrinsic_prefix
          limit = limit_argument ? scalar_value(limit_argument.fetch(:value), context:) : "-1"
          [
            "    {",
            "        long long #{prefix}_dst = (long long)(#{destination.offset});",
            "        long long #{prefix}_src = (long long)(#{source.offset});",
            "        long long #{prefix}_limit = (long long)(#{limit});",
            "        long long #{prefix}_i = 0;",
            "        int #{prefix}_copied_null = 0;",
            *dynamic_valid_address_lines(destination),
            *dynamic_valid_address_lines(source),
            *dynamic_writable_address_lines(destination),
            "        if (#{prefix}_dst < 0 || #{prefix}_src < 0 || #{prefix}_dst >= #{destination.limit} || #{prefix}_src >= #{source.limit} || #{prefix}_limit < -1) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_limit < 0 || #{prefix}_i < #{prefix}_limit) {",
            "            unsigned char #{prefix}_ch;",
            "            if (#{prefix}_dst + #{prefix}_i >= #{destination.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} destination out of range\\n\");",
            "                PF_ABORT();",
            "            }",
            "            if (#{prefix}_src + #{prefix}_i >= #{source.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} missing null terminator\\n\");",
            "                PF_ABORT();",
            "            }",
            "            #{prefix}_ch = #{source.memory}[#{prefix}_src + #{prefix}_i];",
            "            #{destination.memory}[#{prefix}_dst + #{prefix}_i] = #{prefix}_ch;",
            "            #{prefix}_i++;",
            "            if (#{prefix}_ch == 0u) {",
            "                #{prefix}_copied_null = 1;",
            "                break;",
            "            }",
            "        }",
            "        if (#{prefix}_limit < 0 && #{prefix}_copied_null == 0) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_limit >= 0 && #{prefix}_copied_null != 0 && #{prefix}_i < #{prefix}_limit) {",
            "            if (#{prefix}_dst + #{prefix}_i >= #{destination.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} destination out of range\\n\");",
            "                PF_ABORT();",
            "            }",
            "            #{destination.memory}[#{prefix}_dst + #{prefix}_i] = 0u;",
            "            #{prefix}_i++;",
            "        }",
            "    }",
            *emit_pointer_return_assignment(call.fetch(:destination), arguments.fetch(0).fetch(:value), context:)
          ]
        end

        def emit_strcat_call(call, limit_argument, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          destination = memory_address(arguments.fetch(0).fetch(:value), context:)
          ensure_writable_address!(destination)
          source = memory_address(arguments.fetch(1).fetch(:value), context:)
          prefix = next_memory_intrinsic_prefix
          limit = limit_argument ? scalar_value(limit_argument.fetch(:value), context:) : "-1"
          [
            "    {",
            "        long long #{prefix}_dst = (long long)(#{destination.offset});",
            "        long long #{prefix}_src = (long long)(#{source.offset});",
            "        long long #{prefix}_limit = (long long)(#{limit});",
            "        long long #{prefix}_dst_len = 0;",
            "        long long #{prefix}_i = 0;",
            *dynamic_valid_address_lines(destination),
            *dynamic_valid_address_lines(source),
            *dynamic_writable_address_lines(destination),
            "        if (#{prefix}_dst < 0 || #{prefix}_src < 0 || #{prefix}_dst >= #{destination.limit} || #{prefix}_src >= #{source.limit} || #{prefix}_limit < -1) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_dst + #{prefix}_dst_len < #{destination.limit} && #{destination.memory}[#{prefix}_dst + #{prefix}_dst_len] != 0u) {",
            "            #{prefix}_dst_len++;",
            "        }",
            "        if (#{prefix}_dst + #{prefix}_dst_len >= #{destination.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} destination missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_limit < 0 || #{prefix}_i < #{prefix}_limit) {",
            "            unsigned char #{prefix}_ch;",
            "            if (#{prefix}_src + #{prefix}_i >= #{source.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} missing null terminator\\n\");",
            "                PF_ABORT();",
            "            }",
            "            #{prefix}_ch = #{source.memory}[#{prefix}_src + #{prefix}_i];",
            "            if (#{prefix}_ch == 0u) break;",
            "            if (#{prefix}_dst + #{prefix}_dst_len + #{prefix}_i >= #{destination.limit}) {",
            "                fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} destination out of range\\n\");",
            "                PF_ABORT();",
            "            }",
            "            #{destination.memory}[#{prefix}_dst + #{prefix}_dst_len + #{prefix}_i] = #{prefix}_ch;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_dst + #{prefix}_dst_len + #{prefix}_i >= #{destination.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: #{call.fetch(:function_name)} destination out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        #{destination.memory}[#{prefix}_dst + #{prefix}_dst_len + #{prefix}_i] = 0u;",
            "    }",
            *emit_pointer_return_assignment(call.fetch(:destination), arguments.fetch(0).fetch(:value), context:)
          ]
        end

        def emit_strdup_call(call, context:)
          destination_name = call.fetch(:destination)
          raise Frontend::LLVMSubset::ParseError, "strdup result must be assigned" unless destination_name

          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          source = memory_address(arguments.fetch(0).fetch(:value), context:)
          target = context ? inline_register(context, destination_name) : register(destination_name)
          pointer_map = context ? context.fetch(:pointers) : pointers
          pointer_map[destination_name] = EncodedPointer.new(value: target)
          slot = strdup_slots.fetch(destination_name)
          prefix = next_memory_intrinsic_prefix
          [
            "    {",
            "        long long #{prefix}_src = (long long)(#{source.offset});",
            "        long long #{prefix}_i = 0;",
            "        int #{prefix}_copied_null = 0;",
            *dynamic_valid_address_lines(source),
            "        if (#{prefix}_src < 0 || #{prefix}_src >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strdup pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_src + #{prefix}_i < #{source.limit} && #{prefix}_i < #{tape_size}) {",
            "            unsigned char #{prefix}_ch = #{source.memory}[#{prefix}_src + #{prefix}_i];",
            "            llvm_memory[#{slot} + #{prefix}_i] = #{prefix}_ch;",
            "            #{prefix}_i++;",
            "            if (#{prefix}_ch == 0u) {",
            "                #{prefix}_copied_null = 1;",
            "                break;",
            "            }",
            "        }",
            "        if (#{prefix}_copied_null == 0) {",
            "            fprintf(stderr, \"pfc runtime error: strdup missing null terminator or destination out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        #{target} = (unsigned long long)#{slot};",
            "    }"
          ]
        end

        def emit_strtol_call(call, context:, target_override: nil, target_bits: 64)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          unless arguments.fetch(1).fetch(:value).strip == "null"
            raise Frontend::LLVMSubset::ParseError, "strtol endptr is only supported when null"
          end

          source = memory_address(arguments.fetch(0).fetch(:value), context:)
          base = scalar_value(arguments.fetch(2).fetch(:value), context:)
          target = target_override || (context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination)))
          prefix = next_memory_intrinsic_prefix
          [
            "    {",
            "        long long #{prefix}_src = (long long)(#{source.offset});",
            "        long long #{prefix}_i = 0;",
            "        long long #{prefix}_base = (long long)(#{base});",
            "        long long #{prefix}_sign = 1;",
            "        unsigned long long #{prefix}_value = 0ull;",
            "        int #{prefix}_digit = -1;",
            "        int #{prefix}_any = 0;",
            *dynamic_valid_address_lines(source),
            "        if (#{prefix}_src < 0 || #{prefix}_src >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strtol pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while (#{prefix}_src + #{prefix}_i < #{source.limit}) {",
            "            unsigned char #{prefix}_ch = #{source.memory}[#{prefix}_src + #{prefix}_i];",
            "            if (!(#{prefix}_ch == ' ' || #{prefix}_ch == '\\t' || #{prefix}_ch == '\\n' || #{prefix}_ch == '\\v' || #{prefix}_ch == '\\f' || #{prefix}_ch == '\\r')) break;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_src + #{prefix}_i >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strtol missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "        if (#{source.memory}[#{prefix}_src + #{prefix}_i] == '-' || #{source.memory}[#{prefix}_src + #{prefix}_i] == '+') {",
            "            #{prefix}_sign = (#{source.memory}[#{prefix}_src + #{prefix}_i] == '-') ? -1 : 1;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_base == 0) #{prefix}_base = 10;",
            "        if (#{prefix}_base != 10 && #{prefix}_base != 16) {",
            "            fprintf(stderr, \"pfc runtime error: strtol base is unsupported\\n\");",
            "            PF_ABORT();",
            "        }",
            "        if (#{prefix}_base == 16 && #{prefix}_src + #{prefix}_i + 1 < #{source.limit} && #{source.memory}[#{prefix}_src + #{prefix}_i] == '0' && (#{source.memory}[#{prefix}_src + #{prefix}_i + 1] == 'x' || #{source.memory}[#{prefix}_src + #{prefix}_i + 1] == 'X')) {",
            "            #{prefix}_i += 2;",
            "        }",
            "        while (#{prefix}_src + #{prefix}_i < #{source.limit}) {",
            "            unsigned char #{prefix}_ch = #{source.memory}[#{prefix}_src + #{prefix}_i];",
            "            if (#{prefix}_ch >= '0' && #{prefix}_ch <= '9') #{prefix}_digit = (int)(#{prefix}_ch - '0');",
            "            else if (#{prefix}_ch >= 'A' && #{prefix}_ch <= 'F') #{prefix}_digit = (int)(#{prefix}_ch - 'A' + 10);",
            "            else if (#{prefix}_ch >= 'a' && #{prefix}_ch <= 'f') #{prefix}_digit = (int)(#{prefix}_ch - 'a' + 10);",
            "            else #{prefix}_digit = -1;",
            "            if (#{prefix}_digit < 0 || #{prefix}_digit >= #{prefix}_base) break;",
            "            #{prefix}_value = (#{prefix}_value * (unsigned long long)#{prefix}_base) + (unsigned long long)#{prefix}_digit;",
            "            #{prefix}_any = 1;",
            "            #{prefix}_i++;",
            "        }",
            "        if (#{prefix}_src + #{prefix}_i >= #{source.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strtol missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "        if (!#{prefix}_any) #{prefix}_value = 0ull;",
            "        if (#{prefix}_sign < 0) #{prefix}_value = (unsigned long long)(-(long long)#{prefix}_value);",
            "        #{target} = #{unsigned_cast(target_bits)}(#{prefix}_value & #{integer_mask_literal(target_bits)});",
            "    }"
          ]
        end

        def emit_strcmp_call(call, limit_argument, context:)
          arguments = parse_typed_call_arguments(call.fetch(:raw_arguments))
          left = memory_address(arguments.fetch(0).fetch(:value), context:)
          right = memory_address(arguments.fetch(1).fetch(:value), context:)
          target = context ? inline_register(context, call.fetch(:destination)) : register(call.fetch(:destination))
          prefix = next_memory_intrinsic_prefix
          limit = limit_argument ? scalar_value(limit_argument.fetch(:value), context:) : "-1"
          [
            "    {",
            "        long long #{prefix}_left = (long long)(#{left.offset});",
            "        long long #{prefix}_right = (long long)(#{right.offset});",
            "        long long #{prefix}_limit = (long long)(#{limit});",
            "        long long #{prefix}_i = 0;",
            *dynamic_valid_address_lines(left),
            *dynamic_valid_address_lines(right),
            "        #{target} = 0ull;",
            "        if (#{prefix}_left < 0 || #{prefix}_right < 0 || #{prefix}_left >= #{left.limit} || #{prefix}_right >= #{right.limit}) {",
            "            fprintf(stderr, \"pfc runtime error: strcmp pointer out of range\\n\");",
            "            PF_ABORT();",
            "        }",
            "        while ((#{prefix}_limit < 0 || #{prefix}_i < #{prefix}_limit) && #{prefix}_left + #{prefix}_i < #{left.limit} && #{prefix}_right + #{prefix}_i < #{right.limit}) {",
            "            unsigned char #{prefix}_lb = #{left.memory}[#{prefix}_left + #{prefix}_i];",
            "            unsigned char #{prefix}_rb = #{right.memory}[#{prefix}_right + #{prefix}_i];",
            "            if (#{prefix}_lb != #{prefix}_rb || #{prefix}_lb == 0u || #{prefix}_rb == 0u) {",
            "                #{target} = (unsigned long long)(int)((int)#{prefix}_lb - (int)#{prefix}_rb);",
            "                break;",
            "            }",
            "            #{prefix}_i++;",
            "        }",
            "        if ((#{prefix}_limit < 0 || #{prefix}_i < #{prefix}_limit) && (#{prefix}_left + #{prefix}_i >= #{left.limit} || #{prefix}_right + #{prefix}_i >= #{right.limit})) {",
            "            fprintf(stderr, \"pfc runtime error: strcmp missing null terminator\\n\");",
            "            PF_ABORT();",
            "        }",
            "    }"
          ]
        end

        def encoded_string_result(prefix, offset)
          "(((#{prefix}_base_encoded) & (PF_LLVM_GLOBAL_POINTER_TAG | PF_LLVM_READONLY_POINTER_TAG | PF_LLVM_STRING_POINTER_TAG)) | ((unsigned long long)(#{offset}) & PF_LLVM_POINTER_OFFSET_MASK))"
        end
      end
    end
  end
end
