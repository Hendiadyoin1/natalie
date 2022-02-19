require_relative './base_pass'
require_relative './args'
require_relative './rescue'

module Natalie
  class Compiler2
    # This compiler pass transforms AST from the Parser into Intermediate
    # Representation, which we implement using Instructions.
    # You can debug this pass with the `-d p1` CLI flag.
    class Pass1 < BasePass
      def initialize(ast)
        @ast = ast
      end

      # pass used: true to leave the final result on the stack
      def transform(used: true)
        raise 'unexpected AST input' unless @ast.sexp_type == :block
        transform_block(@ast, used: used).flatten
      end

      def transform_expression(exp, used:)
        case exp
        when Sexp
          method = "transform_#{exp.sexp_type}"
          send(method, exp, used: used)
        else
          raise "Unknown expression type: #{exp.inspect}"
        end
      end

      private

      def transform_body(body, used:)
        *body, last = body
        instructions = body.map { |exp| transform_expression(exp, used: false) }
        instructions << transform_expression(last || s(:nil), used: used)
        instructions
      end

      # INDIVIDUAL EXPRESSIONS = = = = =
      # (in alphabetical order)

      def transform_and(exp, used:)
        _, lhs, rhs = exp
        lhs_instructions = transform_expression(lhs, used: true)
        rhs_instructions = transform_expression(rhs, used: true)
        instructions = [
          lhs_instructions,
          DupInstruction.new,
          IfInstruction.new,
          PopInstruction.new,
          rhs_instructions,
          ElseInstruction.new(:if),
          EndInstruction.new(:if),
        ]
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_array(exp, used:)
        _, *items = exp
        instructions = items.map { |item| transform_expression(item, used: true) }
        instructions << CreateArrayInstruction.new(count: items.size)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_block(exp, used:)
        _, *body = exp
        transform_body(body, used: used)
      end

      def transform_block_args(exp, used:)
        # TODO: might need separate logic?
        transform_defn_args(exp, used: used)
      end

      def transform_call(exp, used:, with_block: false)
        _, receiver, message, *args = exp
        instructions = args.map { |arg| transform_expression(arg, used: true) }
        instructions << PushArgcInstruction.new(args.size)
        if receiver.nil?
          instructions << PushSelfInstruction.new
        else
          instructions << transform_expression(receiver, used: true)
        end
        instructions << SendInstruction.new(message, receiver_is_self: receiver.nil?, with_block: with_block)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_case(exp, used:)
        _, var, *whens, else_block = exp
        return transform_expression(else_block, used: used) if whens.empty?
        instructions = []
        if var
          instructions << transform_expression(var, used: true)
          whens.each do |when_statement|
            # case a
            # when b, c, d
            # =>
            # if (a === b || a === c || a === d)
            _, options_array, body = when_statement
            _, *options = options_array
            options.each do |option|
              option_instructions = transform_expression(option, used: true)
              instructions << option_instructions
              instructions << PushArgcInstruction.new(1)
              instructions << DupRelInstruction.new(2)
              instructions << SendInstruction.new(:===, receiver_is_self: false, with_block: false)
              instructions << IfInstruction.new
              instructions << PushTrueInstruction.new
              instructions << ElseInstruction.new(:if)
            end
            instructions << PushFalseInstruction.new
            instructions << [EndInstruction.new(:if)] * options.length
            instructions << IfInstruction.new
            instructions << (body.nil? ? PushNilInstruction.new : transform_expression(body, used: true))
            instructions << ElseInstruction.new(:if)
          end
        else
          # glorified if-else
          whens.each do |when_statement|
            # case
            # when a == b, b == c, c == d
            # =>
            # if (a == b || b == c || c == d)
            _, options, body = when_statement

            # s(:array, option1, option2, ...)
            # =>
            # s(:or, option1, s(:or, option2, ...))
            options = options[2..].reduce(options[1]) { |prev, option| s(:or, prev, option) }
            instructions << transform_expression(options, used: true)
            instructions << IfInstruction.new
            instructions << (body.nil? ? PushNilInstruction.new : transform_expression(body, used: true))
            instructions << ElseInstruction.new(:if)
          end
        end

        instructions << (else_block.nil? ? PushNilInstruction.new : transform_expression(else_block, used: true))

        instructions << [EndInstruction.new(:if)] * whens.length

        # We might need to pop out the var from the stack, due to it always
        # being used after duplication
        instructions << [SwapInstruction.new, PopInstruction.new] if var

        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_cdecl(exp, used:)
        _, name, value = exp
        instructions = [transform_expression(value, used: true)]
        name, prep_instruction = constant_name(name)
        instructions << prep_instruction
        instructions << ConstSetInstruction.new(name)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_class(exp, used:)
        _, name, superclass, *body = exp
        instructions = []
        if superclass
          instructions << transform_expression(superclass, used: true)
        else
          instructions << PushObjectClassInstruction.new
        end
        name, prep_instruction = constant_name(name)
        instructions << prep_instruction
        instructions << DefineClassInstruction.new(name: name)
        instructions += transform_body(body, used: true)
        instructions << EndInstruction.new(:define_class)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_colon2(exp, used:)
        _, namespace, name = exp
        instructions = [
          transform_expression(namespace, used: true),
          ConstFindInstruction.new(name),
        ]
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_colon3(exp, used:)
        return [] unless used
        _, name = exp
        [PushObjectClassInstruction.new, ConstFindInstruction.new(name)]
      end

      def transform_const(exp, used:)
        return [] unless used
        _, name = exp
        [PushSelfInstruction.new, ConstFindInstruction.new(name)]
      end

      def transform_defn(exp, used:)
        _, name, args, *body = exp
        arity = args.size - 1 # FIXME: way more complicated than this :-)
        instructions = []
        instructions << DefineMethodInstruction.new(name: name, arity: arity)
        instructions << transform_defn_args(args, used: true)
        instructions += transform_body(body, used: true)
        instructions << EndInstruction.new(:define_method)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_defn_args(exp, used:)
        return [] unless used
        _, *args = exp

        if args.any? { |arg| arg.is_a?(Sexp) || arg.start_with?('*') }
          return [PushArgsInstruction.new, Args.new(self).transform(exp)].flatten
        end

        args.each_with_index.flat_map do |name, index|
          [PushArgInstruction.new(index), VariableSetInstruction.new(name, local_only: true)]
        end
      end

      def transform_dot2(exp, used:, exclude_end: false)
        _, beginning, ending = exp
        instructions = [
          transform_expression(ending || s(:nil), used: true),
          transform_expression(beginning || s(:nil), used: true),
          PushRangeInstruction.new(exclude_end),
        ]
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_dot3(exp, used:)
        transform_dot2(exp, used: used, exclude_end: true)
      end

      def transform_false(_, used:)
        return [] unless used
        PushFalseInstruction.new
      end

      def transform_gasgn(exp, used:)
        _, name, value = exp
        instructions = [transform_expression(value, used: true), GlobalVariableSetInstruction.new(name)]
        instructions << GlobalVariableGetInstruction.new(name) if used
        instructions
      end

      def transform_gvar(exp, used:)
        return [] unless used
        _, name = exp
        GlobalVariableGetInstruction.new(name)
      end

      def transform_hash(exp, used:)
        _, *items = exp
        raise 'odd number of hash items' if items.size.odd?
        instructions = items.map { |item| transform_expression(item, used: true) }
        instructions << CreateHashInstruction.new(count: items.size / 2)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_iasgn(exp, used:)
        _, name, value = exp
        instructions = [transform_expression(value, used: true), InstanceVariableSetInstruction.new(name)]
        instructions << InstanceVariableGetInstruction.new(name) if used
        instructions
      end

      def transform_if(exp, used:)
        _, condition, true_expression, false_expression = exp
        true_instructions = transform_expression(true_expression || s(:nil), used: true)
        false_instructions = transform_expression(false_expression || s(:nil), used: true)
        instructions = [
          transform_expression(condition, used: true),
          IfInstruction.new,
          true_instructions,
          ElseInstruction.new(:if),
          false_instructions,
          EndInstruction.new(:if),
        ]
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_iter(exp, used:)
        _, call, args, body = exp
        arity = args.size - 1 # FIXME: way more complicated than this :-)
        instructions = []
        instructions << DefineBlockInstruction.new(arity: arity)
        instructions << transform_defn_args(args, used: true)
        instructions << transform_expression(body, used: true)
        instructions << EndInstruction.new(:define_block)
        raise 'unexpected call' unless call.sexp_type == :call
        instructions << transform_call(call, used: used, with_block: true)
        instructions
      end

      def transform_ivar(exp, used:)
        return [] unless used
        _, name = exp
        InstanceVariableGetInstruction.new(name)
      end

      def transform_lasgn(exp, used:)
        _, name, value = exp
        instructions = [transform_expression(value, used: true), VariableSetInstruction.new(name)]
        instructions << VariableGetInstruction.new(name) if used
        instructions
      end

      def transform_lit(exp, used:)
        return [] unless used
        lit = if exp.is_a?(Sexp)
                exp[1]
              else
                exp
              end
        case lit
        when Integer
          PushIntInstruction.new(lit)
        when Float
          PushFloatInstruction.new(lit)
        when Symbol
          PushSymbolInstruction.new(lit)
        when Range
          [transform_lit(lit.end, used: true),
           transform_lit(lit.begin, used: true),
           PushRangeInstruction.new(lit.exclude_end?)]
        else
          raise "I don't yet know how to handle lit: #{lit.inspect}"
        end
      end

      def transform_lvar(exp, used:)
        return [] unless used
        _, name = exp
        VariableGetInstruction.new(name)
      end

      def transform_nil(_, used:)
        return [] unless used
        PushNilInstruction.new
      end

      def transform_or(exp, used:)
        _, lhs, rhs = exp
        lhs_instructions = transform_expression(lhs, used: true)
        rhs_instructions = transform_expression(rhs, used: true)
        instructions = [
          lhs_instructions,
          DupInstruction.new,
          IfInstruction.new,
          ElseInstruction.new(:if),
          PopInstruction.new,
          rhs_instructions,
          EndInstruction.new(:if),
        ]
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_rescue(exp, used:)
        instructions = Rescue.new(self).transform(exp)
        instructions << PopInstruction.new unless used
        instructions
      end

      def transform_self(_, used:)
        return [] unless used
        PushSelfInstruction.new
      end

      def transform_str(exp, used:)
        return [] unless used
        _, str = exp
        PushStringInstruction.new(str, str.size)
      end

      def transform_true(_, used:)
        return [] unless used
        PushTrueInstruction.new
      end

      def transform_yield(exp, used:)
        _, *args = exp
        instructions = args.map { |arg| transform_expression(arg, used: true) }
        instructions << PushArgcInstruction.new(args.size)
        instructions << YieldInstruction.new
        instructions << PopInstruction.new unless used
        instructions
      end

      # HELPERS = = = = = = = = = = = = =

      # returns a pair of [name, prep_instruction]
      # prep_instruction being the instruction(s) needed to get the owner of the constant
      def constant_name(name)
        if name.is_a?(Symbol)
          [name, PushSelfInstruction.new]
        elsif name.sexp_type == :colon2
          _, namespace, name = name
          [name, transform_expression(namespace, used: true)]
        elsif name.sexp_type == :colon3
          _, name = name
          [name, PushObjectClassInstruction.new]
        else
          raise "Unknown constant name type #{name.sexp_type.inspect}"
        end
      end
    end
  end
end
