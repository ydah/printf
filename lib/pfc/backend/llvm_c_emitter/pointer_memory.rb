# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module PointerMemory
        private

        def default_address_space_pointer_type?(type)
          stripped = type.to_s.strip
          stripped == "ptr" || stripped.match?(/\Aptr\s+addrspace\(0\)\z/) || stripped.end_with?("*")
        end
      end
    end
  end
end
