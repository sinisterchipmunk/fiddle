# frozen_string_literal: true
require 'fiddle'
require 'fiddle/value'
require 'fiddle/pack'

module Fiddle
  # A base class for objects representing a C structure
  class CStruct
    # accessor to Fiddle::CStructEntity
    def CStruct.entity_class
      CStructEntity
    end
  end

  # A base class for objects representing a C union
  class CUnion
    # accessor to Fiddle::CUnionEntity
    def CUnion.entity_class
      CUnionEntity
    end
  end

  # Wrapper for arrays within a struct
  class StructArray < Array
    include ValueUtil

    def initialize(ptr, type, initial_values)
      @ptr = ptr
      @type = type
      @align = PackInfo::ALIGN_MAP[type]
      @size = Fiddle::PackInfo::SIZE_MAP[type]
      @pack_format = Fiddle::PackInfo::PACK_MAP[type]
      super(initial_values.collect { |v| unsigned_value(v, type) })
    end

    def to_ptr
      @ptr
    end

    def []=(index, value)
      if index < 0 || index >= size
        raise IndexError, 'index %d outside of array bounds 0...%d' % [index, size]
      end

      to_ptr[index * @align, @size] = [value].pack(@pack_format)
      super(index, value)
    end
  end

  # Wrapper for arrays of structs within a struct
  class NestedStructArray < Array
    def []=(index, value)
      self[index].to_ptr.memcpy(value.to_ptr)
    end
  end

  # Used to construct C classes (CUnion, CStruct, etc)
  #
  # Fiddle::Importer#struct and Fiddle::Importer#union wrap this functionality in an
  # easy-to-use manner.
  module CStructBuilder
    # Construct a new class given a C:
    # * class +klass+ (CUnion, CStruct, or other that provide an
    #   #entity_class)
    # * +types+ (Fiddle::TYPE_INT, Fiddle::TYPE_SIZE_T, etc., see the C types
    #   constants)
    # * corresponding +members+
    #
    # Fiddle::Importer#struct and Fiddle::Importer#union wrap this functionality in an
    # easy-to-use manner.
    #
    # Examples:
    #
    #   require 'fiddle/struct'
    #   require 'fiddle/cparser'
    #
    #   include Fiddle::CParser
    #
    #   types, members = parse_struct_signature(['int i','char c'])
    #
    #   MyStruct = Fiddle::CStructBuilder.create(Fiddle::CUnion, types, members)
    #
    #   MyStruct.malloc(Fiddle::RUBY_FREE) do |obj|
    #     ...
    #   end
    #
    #   obj = MyStruct.malloc(Fiddle::RUBY_FREE)
    #   begin
    #     ...
    #   ensure
    #     obj.call_free
    #   end
    #
    #   obj = MyStruct.malloc
    #   begin
    #     ...
    #   ensure
    #     Fiddle.free obj.to_ptr
    #   end
    #
    def create(klass, types, members)
      new_class = Class.new(klass){
        define_method(:initialize){|addr, func = nil|
          if addr.is_a?(self.class.entity_class)
            @entity = addr
          else
            @entity = self.class.entity_class.new(addr, types, func)
          end
          @entity.assign_names(members)
        }
        define_method(:[]) { |*args| @entity.send(:[], *args) }
        define_method(:[]=) { |*args| @entity.send(:[]=, *args) }
        define_method(:to_ptr){ @entity }
        define_method(:to_i){ @entity.to_i }
        define_singleton_method(:types) { types }
        define_singleton_method(:members) { members }
        members.each{|name|
          if name.kind_of?(Array) # name is a nested struct
            next if method_defined?(name[0])
            name = name[0]
          end
          define_method(name){ @entity[name] }
          define_method(name + "="){|val| @entity[name] = val }
        }
        size = klass.entity_class.size(types)
        define_singleton_method(:size) { size }
        define_singleton_method(:malloc) do |func=nil|
          if block_given?
            entity_class.malloc(types, func, size) do |entity|
              yield new(entity)
            end
          else
            new(entity_class.malloc(types, func, size))
          end
        end
      }
      return new_class
    end
    module_function :create
  end

  # A pointer to a C structure
  class CStructEntity < Fiddle::Pointer
    include PackInfo
    include ValueUtil

    # Allocates a C struct with the +types+ provided.
    #
    # See Fiddle::Pointer.malloc for memory management issues.
    def CStructEntity.malloc(types, func = nil, size = size(types), &block)
      if block_given?
        super(size, func) do |struct|
          struct.set_ctypes types
          yield struct
        end
      else
        struct = super(size, func)
        struct.set_ctypes types
        struct
      end
    end

    # Returns the offset for the packed sizes for the given +types+.
    #
    #   Fiddle::CStructEntity.size(
    #     [ Fiddle::TYPE_DOUBLE,
    #       Fiddle::TYPE_INT,
    #       Fiddle::TYPE_CHAR,
    #       Fiddle::TYPE_VOIDP ]) #=> 24
    def CStructEntity.size(types)
      offset = 0

      max_align = types.map { |type, count = 1|
        last_offset = offset

        if type.kind_of?(Array) # type is a nested array representing a nested struct
          align = CStructEntity.size(type)
          offset = PackInfo.align(last_offset, align) +
                  (align * (count || 1))
        else
          align = PackInfo::ALIGN_MAP[type]
          offset = PackInfo.align(last_offset, align) +
                   (PackInfo::SIZE_MAP[type] * count)
        end

        align
      }.max

      PackInfo.align(offset, max_align)
    end

    # Wraps the C pointer +addr+ as a C struct with the given +types+.
    #
    # When the instance is garbage collected, the C function +func+ is called.
    #
    # See also Fiddle::Pointer.new
    def initialize(addr, types, func = nil)
      if func && addr.is_a?(Pointer) && addr.free
        raise ArgumentError, 'free function specified on both underlying struct Pointer and when creating a CStructEntity - who do you want to free this?'
      end
      @addr = addr
      set_ctypes(types)
      super(addr, @size, func)
    end

    # Set the names of the +members+ in this C struct
    def assign_names(members)
      @members = members.map { |member| member.kind_of?(Array) ? member[0] : member }

      @nested_structs = {}
      @ctypes.each_with_index do |ty, idx|
        if ty.kind_of?(Array) && ty[0].kind_of?(Array)
          member = members[idx]
          member = member[0] if member.kind_of?(Array)
          entity_class = CStructBuilder.create(CStruct, ty[0], members[idx][1])
          @nested_structs[member] ||= if ty[1]
            NestedStructArray.new(ty[1].times.map do |i|
              entity_class.new(@addr + @offset[idx] + i * CStructEntity.size(ty[0]))
            end)
          else
            entity_class.new(@addr + @offset[idx])
          end
        end
      end
    end

    # Calculates the offsets and sizes for the given +types+ in the struct.
    def set_ctypes(types)
      @ctypes = types
      @offset = []
      offset = 0

      max_align = types.map { |type, count = 1|
        orig_offset = offset
        if type.kind_of?(Array) # type is a nested array representing a nested struct
          align = CStructEntity.size(type)
          offset = PackInfo.align(orig_offset, align)
          @offset << offset
          offset += (align * (count || 1))
        else
          align = ALIGN_MAP[type]
          offset = PackInfo.align(orig_offset, align)
          @offset << offset
          offset += (SIZE_MAP[type] * (count || 1))
        end

        align
      }.max

      @size = PackInfo.align(offset, max_align)
    end

    # Fetch struct member +name+ if only one argument is specified. If two
    # arguments are specified, the first is an offset and the second is a
    # length and this method returns the string of +length+ bytes beginning at
    # +offset+.
    #
    # Examples:
    #
    #     my_struct = struct(['int id']).malloc
    #     my_struct.id = 1
    #     my_struct['id'] # => 1
    #     my_struct[0, 4] # => "\x01\x00\x00\x00".b
    #
    def [](*args)
      return super(*args) if args.size > 1
      name = args[0]
      idx = @members.index(name)
      if( idx.nil? )
        raise(ArgumentError, "no such member: #{name}")
      end
      ty = @ctypes[idx]
      if( ty.is_a?(Array) )
        if ty.first.kind_of?(Array)
          return @nested_structs[name]
        else
          r = super(@offset[idx], SIZE_MAP[ty[0]] * ty[1])
        end
      else
        r = super(@offset[idx], SIZE_MAP[ty.abs])
      end
      packer = Packer.new([ty])
      val = packer.unpack([r])
      case ty
      when Array
        case ty[0]
        when TYPE_VOIDP
          val = val.collect{|v| Pointer.new(v)}
        end
      when TYPE_VOIDP
        val = Pointer.new(val[0])
      else
        val = val[0]
      end
      if( ty.is_a?(Integer) && (ty < 0) )
        return unsigned_value(val, ty)
      elsif( ty.is_a?(Array) && (ty[0] < 0) )
        return StructArray.new(self + @offset[idx], ty[0], val)
      else
        return val
      end
    end

    # Set struct member +name+, to value +val+. If more arguments are
    # specified, writes the string of bytes to the memory at the given
    # +offset+ and +length+.
    #
    # Examples:
    #
    #     my_struct = struct(['int id']).malloc
    #     my_struct['id'] = 1
    #     my_struct[0, 4] = "\x01\x00\x00\x00".b
    #     my_struct.id # => 1
    #
    def []=(*args)
      return super(*args) if args.size > 2
      name, val = *args
      idx = @members.index(name)
      if( idx.nil? )
        raise(ArgumentError, "no such member: #{name}")
      end
      if @nested_structs[name]
        if @nested_structs[name].kind_of?(Array)
          val.size.times do |i|
            @nested_structs[name][i].to_ptr.memcpy(val[i].to_ptr)
          end
        else
          @nested_structs[name].to_ptr.memcpy(val.to_ptr)
        end
        return
      end
      ty  = @ctypes[idx]
      packer = Packer.new([ty])
      val = wrap_arg(val, ty, [])
      buff = packer.pack([val].flatten())
      super(@offset[idx], buff.size, buff)
      if( ty.is_a?(Integer) && (ty < 0) )
        return unsigned_value(val, ty)
      elsif( ty.is_a?(Array) && (ty[0] < 0) )
        return val.collect{|v| unsigned_value(v,ty[0])}
      else
        return val
      end
    end

    undef_method :size=
    def to_s() # :nodoc:
      super(@size)
    end
  end

  # A pointer to a C union
  class CUnionEntity < CStructEntity
    include PackInfo

    # Returns the size needed for the union with the given +types+.
    #
    #   Fiddle::CUnionEntity.size(
    #     [ Fiddle::TYPE_DOUBLE,
    #       Fiddle::TYPE_INT,
    #       Fiddle::TYPE_CHAR,
    #       Fiddle::TYPE_VOIDP ]) #=> 8
    def CUnionEntity.size(types)
      types.map { |type, count = 1|
        if type.kind_of?(Array) # type is a nested array representing a nested struct
          CStructEntity.size(type) * (count || 1)
        else
          PackInfo::SIZE_MAP[type] * count
        end
      }.max
    end

    # Calculate the necessary offset and for each union member with the given
    # +types+
    def set_ctypes(types)
      @ctypes = types
      @offset = Array.new(types.length, 0)
      @size   = self.class.size types
    end
  end
end
