# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module TypeLayout
        private

        def vector_type_match(type)
          type.to_s.match(/\A<(\d+)\s+x\s+(i(1|8|16|32|64)|ptr)>\z/)
        end

        def vector_element_count(type)
          match = vector_type_match(type)
          raise Frontend::LLVMSubset::ParseError, "unsupported vector type: #{type}" unless match

          match[1].to_i
        end

        def vector_element_bits(type)
          match = vector_type_match(type)
          raise Frontend::LLVMSubset::ParseError, "unsupported vector type: #{type}" unless match

          raise Frontend::LLVMSubset::ParseError, "pointer vector lanes do not have integer bits: #{type}" if match[2] == "ptr"

          match[3].to_i
        end

        def vector_element_type(type)
          match = vector_type_match(type)
          raise Frontend::LLVMSubset::ParseError, "unsupported vector type: #{type}" unless match

          match[2]
        end

        def vector_element_width(type)
          element = vector_element_type(type)
          return pointer_size if element == "ptr"

          byte_width(element.delete_prefix("i").to_i)
        end

        def i128_type?(type)
          type.to_s.strip == "i128"
        end
      end
    end
  end
end
