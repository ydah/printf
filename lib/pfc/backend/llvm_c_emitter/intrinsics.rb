# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module Intrinsics
        private

        def intrinsic_name?(name)
          name.to_s.start_with?("llvm.")
        end
      end
    end
  end
end
