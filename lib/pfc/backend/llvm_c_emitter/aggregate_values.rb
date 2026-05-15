# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module AggregateValues
        VECTOR_BINARY_OPERATORS = %w[add sub mul and or xor shl lshr ashr].freeze
        VECTOR_ICMP_PREDICATES = %w[eq ne ugt uge ult ule sgt sge slt sle].freeze

        private

        def vector_binary_operator?(operator)
          VECTOR_BINARY_OPERATORS.include?(operator)
        end

        def vector_icmp_predicate?(predicate)
          VECTOR_ICMP_PREDICATES.include?(predicate)
        end

        def emit_i128_binary(destination, operator, left, right, context: nil)
          unless %w[add sub and or xor].include?(operator)
            raise Frontend::LLVMSubset::ParseError, "unsupported i128 binary operator: #{operator}"
          end

          target = context ? inline_register(context, destination) : register(destination)
          high_target = context ? nil : i128_high_register(destination)
          left_low = i128_low64_value(left, context:)
          right_low = i128_low64_value(right, context:)
          left_high = i128_high64_value(left, context:)
          right_high = i128_high64_value(right, context:)

          case operator
          when "add"
            lines = ["    #{target} = ((#{left_low}) + (#{right_low}));"]
            lines << "    #{high_target} = ((#{left_high}) + (#{right_high}) + ((#{target} < (#{left_low})) ? 1ull : 0ull));" if high_target
            lines
          when "sub"
            lines = ["    #{target} = ((#{left_low}) - (#{right_low}));"]
            lines << "    #{high_target} = ((#{left_high}) - (#{right_high}) - (((#{left_low}) < (#{right_low})) ? 1ull : 0ull));" if high_target
            lines
          else
            op = { "and" => "&", "or" => "|", "xor" => "^" }.fetch(operator)
            low = "((#{left_low}) #{op} (#{right_low}))"
            high = "((#{left_high}) #{op} (#{right_high}))"
            lines = ["    #{target} = #{low};"]
            lines << "    #{high_target} = #{high};" if high_target
            lines
          end
        end

        def emit_vector_binary(line)
          unless vector_binary_operator?(line.operator)
            raise Frontend::LLVMSubset::ParseError, "unsupported vector binary operator: #{line.operator}"
          end

          aggregate = aggregate_register(line.destination)
          left_source = aggregate_value_bytes(line.left, line.vector_type)
          right_source = aggregate_value_bytes(line.right, line.vector_type)
          width = byte_width(line.bits)
          prefix = next_aggregate_copy_prefix
          left_value = left_source ? "pf_llvm_load(#{left_source}, #{prefix}_i * #{width}, #{width})" : "0ull"
          right_value = right_source ? "pf_llvm_load(#{right_source}, #{prefix}_i * #{width}, #{width})" : "0ull"
          expression = binary_expression(line.operator, line.bits, left_value, right_value)
          [
            "    {",
            "        int #{prefix}_i = 0;",
            "        for (#{prefix}_i = 0; #{prefix}_i < #{vector_element_count(line.vector_type)}; #{prefix}_i++) {",
            "            pf_llvm_store(#{aggregate.fetch(:name)}, #{prefix}_i * #{width}, (unsigned long long)((#{expression}) & #{integer_mask_literal(line.bits)}), #{width});",
            "        }",
            "    }"
          ]
        end

        def emit_vector_select(line)
          aggregate = aggregate_register(line.destination)
          condition_source = aggregate_value_bytes(line.condition, line.condition_type)
          true_source = aggregate_value_bytes(line.true_value, line.vector_type)
          false_source = aggregate_value_bytes(line.false_value, line.vector_type)
          width = byte_width(line.bits)
          prefix = next_aggregate_copy_prefix
          condition = condition_source ? "pf_llvm_load(#{condition_source}, #{prefix}_i, 1)" : "0ull"
          true_lane = true_source ? "pf_llvm_load(#{true_source}, #{prefix}_i * #{width}, #{width})" : "0ull"
          false_lane = false_source ? "pf_llvm_load(#{false_source}, #{prefix}_i * #{width}, #{width})" : "0ull"
          [
            "    {",
            "        int #{prefix}_i = 0;",
            "        for (#{prefix}_i = 0; #{prefix}_i < #{vector_element_count(line.vector_type)}; #{prefix}_i++) {",
            "            pf_llvm_store(#{aggregate.fetch(:name)}, #{prefix}_i * #{width}, (#{condition}) != 0u ? (#{true_lane}) : (#{false_lane}), #{width});",
            "        }",
            "    }"
          ]
        end

        def emit_vector_icmp(line)
          unless vector_icmp_predicate?(line.predicate)
            raise Frontend::LLVMSubset::ParseError, "unsupported vector icmp predicate: #{line.predicate}"
          end

          aggregate = aggregate_register(line.destination)
          left_source = aggregate_value_bytes(line.left, line.operand_vector_type)
          right_source = aggregate_value_bytes(line.right, line.operand_vector_type)
          width = byte_width(line.bits)
          prefix = next_aggregate_copy_prefix
          left_value = left_source ? "pf_llvm_load(#{left_source}, #{prefix}_i * #{width}, #{width})" : "0ull"
          right_value = right_source ? "pf_llvm_load(#{right_source}, #{prefix}_i * #{width}, #{width})" : "0ull"
          if line.predicate.start_with?("s")
            left_value = signed_expression(left_value, line.bits)
            right_value = signed_expression(right_value, line.bits)
          end
          expression = "((#{left_value}) #{icmp_operator(line.predicate)} (#{right_value}))"
          [
            "    {",
            "        int #{prefix}_i = 0;",
            "        for (#{prefix}_i = 0; #{prefix}_i < #{vector_element_count(line.vector_type)}; #{prefix}_i++) {",
            "            pf_llvm_store(#{aggregate.fetch(:name)}, #{prefix}_i, #{expression} ? 1ull : 0ull, 1);",
            "        }",
            "    }"
          ]
        end

        def emit_i128_extend(destination, operator, from_bits, value, context: nil)
          unless %w[zext sext].include?(operator) && from_bits < 128
            raise Frontend::LLVMSubset::ParseError, "unsupported i128 cast"
          end

          target = context ? inline_register(context, destination) : register(destination)
          high_target = context ? nil : i128_high_register(destination)
          source = context ? inline_value(value, context) : llvm_value(value)
          low = operator == "sext" ? cast_expression("sext", from_bits, 64, source) : "((#{source}) & #{integer_mask_literal(from_bits)})"
          high = operator == "sext" ? "(((#{source}) & #{sign_bit_literal(from_bits)}) ? ~0ull : 0ull)" : "0ull"
          lines = ["    #{target} = #{low};"]
          lines << "    #{high_target} = #{high};" if high_target
          lines
        end

        def emit_i128_select(destination, condition, true_value, false_value, context: nil)
          target = context ? inline_register(context, destination) : register(destination)
          high_target = context ? nil : i128_high_register(destination)
          cond = context ? inline_value(condition, context) : llvm_value(condition)
          lines = [
            "    #{target} = ((#{cond}) != 0u) ? #{i128_low64_value(true_value, context:)} : #{i128_low64_value(false_value, context:)};"
          ]
          lines << "    #{high_target} = ((#{cond}) != 0u) ? #{i128_high64_value(true_value, context:)} : #{i128_high64_value(false_value, context:)};" if high_target
          lines
        end

        def emit_i128_icmp(destination, predicate, left, right, context: nil)
          unless %w[eq ne ugt uge ult ule sgt sge slt sle].include?(predicate)
            raise Frontend::LLVMSubset::ParseError, "unsupported i128 icmp predicate: #{predicate}"
          end

          target = context ? inline_register(context, destination) : register(destination)
          left_value = i128_low64_value(left, context:)
          right_value = i128_low64_value(right, context:)
          left_high = i128_high64_value(left, context:)
          right_high = i128_high64_value(right, context:)
          expression = i128_compare_expression(predicate, left_value, right_value, left_high, right_high)
          ["    #{target} = (#{expression}) ? 1u : 0u;"]
        end

        def i128_low64_value(raw, context: nil)
          token = raw.to_s.strip.split(/\s+/).last
          return "0ull" if token == "false" || token == "undef" || token == "poison" || token == "zeroinitializer"
          return "#{token.to_i & integer_mask(64)}ull" if token.match?(/\A-?\d+\z/)
          return context.fetch(:values).fetch(token) if context && context.fetch(:values).key?(token)
          return register(token) if token.match?(/\A#{NAME}\z/)

          llvm_value(raw)
        end

        def i128_high64_value(raw, context: nil)
          token = raw.to_s.strip.split(/\s+/).last
          return "0ull" if token == "false" || token == "undef" || token == "poison" || token == "zeroinitializer"
          return "#{(token.to_i >> 64) & integer_mask(64)}ull" if token.match?(/\A-?\d+\z/)
          return "0ull" if context && context.fetch(:values).key?(token)
          return i128_high_register(token) if token.match?(/\A#{NAME}\z/) && i128_high_registers.key?(token)
          return "0ull" if token.match?(/\A#{NAME}\z/)

          "0ull"
        end

        def i128_compare_expression(predicate, left_value, right_value, left_high, right_high)
          unsigned_gt = "(((#{left_high}) > (#{right_high})) || (((#{left_high}) == (#{right_high})) && ((#{left_value}) > (#{right_value}))))"
          unsigned_ge = "(((#{left_high}) > (#{right_high})) || (((#{left_high}) == (#{right_high})) && ((#{left_value}) >= (#{right_value}))))"
          unsigned_lt = "(((#{left_high}) < (#{right_high})) || (((#{left_high}) == (#{right_high})) && ((#{left_value}) < (#{right_value}))))"
          unsigned_le = "(((#{left_high}) < (#{right_high})) || (((#{left_high}) == (#{right_high})) && ((#{left_value}) <= (#{right_value}))))"
          left_sign = "((#{left_high}) & 9223372036854775808ull)"
          right_sign = "((#{right_high}) & 9223372036854775808ull)"

          case predicate
          when "eq" then "(((#{left_value}) == (#{right_value})) && ((#{left_high}) == (#{right_high})))"
          when "ne" then "(((#{left_value}) != (#{right_value})) || ((#{left_high}) != (#{right_high})))"
          when "ugt" then unsigned_gt
          when "uge" then unsigned_ge
          when "ult" then unsigned_lt
          when "ule" then unsigned_le
          when "sgt" then "(((#{left_sign}) != (#{right_sign})) ? ((#{right_sign}) != 0ull) : (#{unsigned_gt}))"
          when "sge" then "(((#{left_sign}) != (#{right_sign})) ? ((#{right_sign}) != 0ull) : (#{unsigned_ge}))"
          when "slt" then "(((#{left_sign}) != (#{right_sign})) ? ((#{left_sign}) != 0ull) : (#{unsigned_lt}))"
          when "sle" then "(((#{left_sign}) != (#{right_sign})) ? ((#{left_sign}) != 0ull) : (#{unsigned_le}))"
          end
        end
      end
    end
  end
end
