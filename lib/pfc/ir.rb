# frozen_string_literal: true

module PFC
  module IR
    class Program
      attr_reader :instructions

      def initialize(instructions)
        @instructions = instructions.freeze
      end

      def ==(other)
        other.is_a?(Program) && instructions == other.instructions
      end

      def inspect
        "Program(#{instructions.map(&:inspect).join(', ')})"
      end
    end

    class AddCell
      attr_reader :delta

      def initialize(delta)
        @delta = Integer(delta)
      end

      def ==(other)
        other.is_a?(AddCell) && delta == other.delta
      end

      def inspect
        "AddCell(#{delta})"
      end
    end

    class MovePtr
      attr_reader :delta

      def initialize(delta)
        @delta = Integer(delta)
      end

      def ==(other)
        other.is_a?(MovePtr) && delta == other.delta
      end

      def inspect
        "MovePtr(#{delta})"
      end
    end

    class OutputCell
      def ==(other)
        other.is_a?(OutputCell)
      end

      def inspect
        "OutputCell"
      end
    end

    class InputCell
      def ==(other)
        other.is_a?(InputCell)
      end

      def inspect
        "InputCell"
      end
    end

    class ClearCell
      def ==(other)
        other.is_a?(ClearCell)
      end

      def inspect
        "ClearCell"
      end
    end

    class SetCell
      attr_reader :value

      def initialize(value)
        @value = Integer(value)
      end

      def ==(other)
        other.is_a?(SetCell) && value == other.value
      end

      def inspect
        "SetCell(#{value})"
      end
    end

    class TransferCell
      attr_reader :transfers

      def initialize(transfers)
        @transfers = transfers.map do |offset, scale|
          [Integer(offset), Integer(scale)]
        end.freeze
      end

      def ==(other)
        other.is_a?(TransferCell) && transfers == other.transfers
      end

      def inspect
        "TransferCell(#{transfers.map { |offset, scale| "#{offset}:#{scale}" }.join(', ')})"
      end
    end

    class Loop
      attr_reader :body

      def initialize(body)
        @body = body.freeze
      end

      def ==(other)
        other.is_a?(Loop) && body == other.body
      end

      def inspect
        "Loop(#{body.map(&:inspect).join(', ')})"
      end
    end
  end
end
