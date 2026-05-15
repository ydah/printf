# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module LibCStringFunctions
        private

        def emit_libc_string_memory_call(call, context: nil)
          case call.fetch(:function_name)
          when "memcmp" then emit_memcmp_call(call, context:)
          when "memchr" then emit_memchr_call(call, context:)
          when "strchr" then emit_strchr_call(call, reverse: false, context:)
          when "strrchr" then emit_strchr_call(call, reverse: true, context:)
          when "strpbrk" then emit_strpbrk_call(call, context:)
          when "strspn" then emit_strspan_call(call, stop_on_match: false, context:)
          when "strcspn" then emit_strspan_call(call, stop_on_match: true, context:)
          when "strcmp" then emit_strcmp_call(call, nil, context:)
          else emit_strcmp_call(call, parse_typed_call_arguments(call.fetch(:raw_arguments)).fetch(2), context:)
          end
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
