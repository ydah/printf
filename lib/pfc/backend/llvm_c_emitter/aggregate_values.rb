# frozen_string_literal: true

module PFC
  module Backend
    class LLVMCEmitter
      module AggregateValues
        VECTOR_BINARY_OPERATORS = %w[add sub and or xor].freeze

        private

        def vector_binary_operator?(operator)
          VECTOR_BINARY_OPERATORS.include?(operator)
        end
      end
    end
  end
end
