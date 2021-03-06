module Duby::AST
  class Body < Node
    def initialize(parent, line_number, &block)
      super(parent, line_number, &block)
    end

    # Type of a block is the type of its final element
    def infer(typer)
      unless @inferred_type
        @typer ||= typer
        @self_type ||= typer.self_type
        if children.size == 0
          @inferred_type = typer.no_type
        else
          children.each {|child| @inferred_type = typer.infer(child)}
        end

        if @inferred_type
          resolved!
        else
          typer.defer(self)
        end
      end

      @inferred_type
    end

    def <<(node)
      super
      if @typer
        orig_self = @typer.self_type
        @typer.known_types['self'] = @self_type
        @typer.infer(node)
        @typer.known_types['self'] = orig_self
      end
      self
    end
  end

  class ScopedBody < Body
    include Scope
  end

  class Block < Node
    include Scoped
    include Scope
    include Java::DubyLangCompiler::Block
    child :args
    child :body

    def initialize(parent, position, &block)
      super(parent, position) do
        static_scope.parent = scope.static_scope
        yield(self) if block_given?
      end
    end

    def prepare(typer, method)
      duby = typer.transformer
      interface = method.argument_types[-1]
      outer_class = scope.defining_class
      binding = scope.binding_type(duby)
      name = "#{outer_class.name}$#{duby.tmp}"
      klass = duby.define_closure(position, name, outer_class)
      klass.interfaces = [interface]
      klass.define_constructor(position,
                               ['binding', binding]) do |c|
          duby.eval("@binding = binding", '-', c, 'binding')
      end
      
      # find all methods which would not otherwise be on java.lang.Object
      impl_methods = find_methods(interface).select do |m|
        begin
          obj_m = java.lang.Object.java_class.java_method m.name, *m.parameter_types
        rescue NameError
          # not found on Object
          next true
        end
        # found on Object
        next false
      end

      # TODO: find a nice way to closure-impl multiple methods
      # perhaps something like
      # Collections.sort(list) do
      #   def equals(other); self == other; end
      #   def compareTo(x,y); Comparable(x).compareTo(y); end
      # end
      raise "Multiple abstract methods found; cannot use block" if impl_methods.size > 1
      impl_methods.each do |method|
        mdef = klass.define_method(position,
                                   method.name,
                                   method.actual_return_type,
                                   args.dup)
        mdef.static_scope = static_scope
        mdef.body = body.dup
        mdef.binding_type = binding
        typer.infer(mdef.body)
      end
      call = parent
      instance = Call.new(call, position, 'new')
      instance.target = Constant.new(call, position, name)
      instance.parameters = [
        BindingReference.new(instance, position, binding)
      ]
      call.parameters << instance
      call.block = nil
      typer.infer(instance)
    end

    def find_methods(interface)
      methods = []
      interfaces = [interface]
      until interfaces.empty?
        interface = interfaces.pop
        methods += interface.declared_instance_methods.select {|m| m.abstract?}
        interfaces.concat(interface.interfaces)
      end
      methods
    end
  end

  class BindingReference < Node
    def initialize(parent, position, type)
      super(parent, position)
      @inferred_type = type
    end

    def infer(typer)
      resolved! unless resolved?
      @inferred_type
    end
  end

  class Noop < Node
    def infer(typer)
      resolved!
      @inferred_type ||= typer.no_type
    end
  end

  class Script < Node
    include Scope
    include Binding
    child :body

    attr_accessor :defining_class

    def initialize(parent, line_number, &block)
      super(parent, line_number, children, &block)
    end

    def infer(typer)
      @defining_class ||= typer.self_type
      @inferred_type ||= typer.infer(body) || (typer.defer(self); nil)
    end
  end
end