// Copyright (c) 2025 Mateusz Stadnik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

//! This module provides basic object oriented programming features in Zig.

const std = @import("std");

fn deduce_type(info: anytype, object_type: anytype) type {
    if (info.pointer.is_const) {
        return *const object_type;
    }
    return *object_type;
}

fn prune_type_info(info: anytype) type {
    if (info.pointer.is_const) {
        return *const anyopaque;
    }
    return *anyopaque;
}

fn get_vcall_args(comptime fun: anytype) type {
    const params = @typeInfo(@TypeOf(fun)).@"fn".params;
    if (params.len == 0) {
        return .{};
    }
    comptime var args: []const type = &.{}; // The first parameter is always the object pointer
    for (params[1..]) |param| {
        const arg: []const type = &.{param.type.?};
        args = args ++ arg;
    }
    return std.meta.Tuple(args);
}

fn genVTableEntry(comptime Method: anytype, name: [:0]const u8) std.builtin.Type.StructField {
    const MethodType = @TypeOf(Method);
    const SelfType = @typeInfo(MethodType).@"fn".params[0].type.?;
    const Type = prune_type_info(@typeInfo(SelfType));
    const ReturnType = @typeInfo(@TypeOf(Method)).@"fn".return_type.?;
    const TupleArgs = get_vcall_args(Method);
    const FinalType = ?*const fn (ptr: Type, args: TupleArgs) ReturnType;
    return .{
        .name = name,
        .type = FinalType,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 0,
    };
}

fn BuildVTable(comptime InterfaceType: anytype, comptime Type: type) type {
    comptime var fields: []const std.builtin.Type.StructField = &[_]std.builtin.Type.StructField{};
    inline for (std.meta.declarations(InterfaceType(Type))) |d| {
        if (std.meta.hasMethod(InterfaceType(Type), d.name)) {
            const Method = @field(InterfaceType(Type), d.name);
            fields = fields ++ &[_]std.builtin.Type.StructField{genVTableEntry(Method, d.name)};
        }
    }
    const DestructorType = ?*const fn (ptr: *anyopaque, args: std.meta.Tuple(&.{std.mem.Allocator})) void;

    fields = fields ++ &[_]std.builtin.Type.StructField{.{
        .name = "__destructor",
        .type = DestructorType,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = 0,
    }};
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .is_tuple = false,
        .fields = fields,
        .decls = &.{},
    } });
}

fn decorate_with_const(comptime T: type, comptime BaseType: type) type {
    if (@typeInfo(T).pointer.is_const) {
        return *const BaseType;
    } else {
        return *BaseType;
    }
}

fn gen_vcall(Type: type, ArgsType: anytype, name: []const u8, index: u32, ObjectType: type) type {
    return struct {
        const RetType = @typeInfo(@TypeOf(ArgsType)).@"fn".return_type.?;
        const Params = @typeInfo(@TypeOf(ArgsType)).@"fn".params;
        const SelfType = Params[0].type.?;
        comptime {
            if (@typeInfo(SelfType) != .pointer) {
                @compileError("First argument of virtual function must be a pointer to the object type, failed for: " ++ @typeName(Type) ++ "::" ++ name ++ " with self type: " ++ @typeName(SelfType));
            }
        }

        fn call(ptr: prune_type_info(@typeInfo(SelfType)), call_params: get_vcall_args(ArgsType)) RetType {
            std.debug.assert(@typeInfo(SelfType) == .pointer);
            const self: decorate_with_const(SelfType, Type) = @ptrCast(@alignCast(ptr));
            if (index == 0 or std.mem.eql(u8, name, "delete")) {
                return @call(.auto, @field(Type, name), .{self} ++ call_params);
            } else {
                // seek for parent that has the method
                comptime var ChildType = ObjectType;
                var base: decorate_with_const(SelfType, anyopaque) = self;
                inline while (@hasField(ChildType, "base")) {
                    const BaseType = ChildType;
                    ChildType = @FieldType(ChildType, "base");
                    base = &@field(@as(decorate_with_const(SelfType, BaseType), @ptrCast(@alignCast(base))), "base");

                    // base = &@field(@as(decorate_with_const(SelfType, BaseType), @ptrCast(@alignCast(base))), "base");
                    // if child has the method then it's the one we want
                    if (@hasDecl(ChildType, name)) {
                        // for (0..index) |_| {
                        // base = &@as(BaseType, @ptrCast(base)).base;
                        return @call(.auto, @field(ChildType, name), .{@as(decorate_with_const(@TypeOf(ptr), ChildType), @ptrCast(@alignCast(base)))} ++ call_params);
                    }
                }
            }
        }
    };
}

fn GenerateClass(comptime InterfaceType: type) type {
    return struct {
        fn __build_vtable_chain(chain: []const type) InterfaceType.Self.VTable {
            var vtable: InterfaceType.Self.VTable = undefined;
            for (std.meta.fields(InterfaceType.Self.VTable)) |field| {
                @field(vtable, field.name) = null; // Initialize all fields to null
            }
            var index: isize = chain.len - 1;
            inline while (index >= 0) : (index -= 1) {
                const base = chain[index];
                for (std.meta.fields(InterfaceType.Self.VTable)) |field| {
                    if (std.meta.hasMethod(base, field.name)) {
                        const field_type = @field(base, field.name);
                        const vcall = gen_vcall(base, field_type, field.name, index, chain[0]);
                        const VTableCallType = *const @TypeOf(vcall.call);
                        const VTableEntryType = @typeInfo(@TypeOf(@field(vtable, field.name))).optional.child;
                        if (VTableCallType != VTableEntryType) {
                            @compileError("Virtual call type mismatch for '" ++ field.name ++ "' in interface: " ++ @typeName(InterfaceType) ++ "\n" ++ "Expected: " ++ @typeName(VTableEntryType) ++ "\n" ++ "Got:      " ++ @typeName(VTableCallType) ++ "\n" ++ "Chain: " ++ std.fmt.comptimePrint("{any}", .{chain}));
                        }
                        @field(vtable, field.name) = vcall.call;
                    }
                }
            }

            inline for (std.meta.fields(InterfaceType.Self.VTable)) |field| {
                if (@field(vtable, field.name) == null) {
                    @compileError("Pure virtual function '" ++ field.name ++ "' for interface: " ++ @typeName(InterfaceType) ++ "\n" ++ "Chain: " ++ std.fmt.comptimePrint("{any}", .{chain}));
                }
            }
            return vtable;
        }

        pub fn __init_chain(ptr: anytype, chain: []const type, allocator: ?std.mem.Allocator, reference_counter: ?*i32) InterfaceType.Self {
            const gen_vtable = struct {
                const Self = @TypeOf(ptr.*);
                const vtable = __build_vtable_chain(chain);
            };

            if (@hasField(InterfaceType.Self, "__refcount")) {
                return InterfaceType.Self{
                    .__vtable = &gen_vtable.vtable,
                    .__ptr = @ptrCast(ptr),
                    .__interface_allocator = allocator,
                    .__refcount = reference_counter,
                };
            } else {
                return InterfaceType.Self{
                    .__vtable = &gen_vtable.vtable,
                    .__ptr = @ptrCast(ptr),
                    .__interface_allocator = allocator,
                };
            }
        }
        pub usingnamespace InterfaceType;
    };
}

fn deduce_interface(comptime Base: type) type {
    comptime var base: type = Base;
    while (true) {
        if (base.Base == null) {
            return base;
        }
        base = Base.Base.?;
    }
    return Base;
}

fn build_inheritance_chain(comptime Base: type, comptime Derived: type) []const type {
    comptime var chain: []const type = &.{};

    const arg: []const type = &.{Derived};
    chain = chain ++ arg;

    comptime var current: ?type = Base;
    inline while (current != null) {
        const a: []const type = &.{current.?};
        chain = chain ++ a;
        current = current.?.Base;
    }
    return chain;
}

fn DeriveFromChain(comptime chain: []const type, comptime Derived: anytype) type {
    return struct {
        pub const Base: ?type = if (chain.len > 1) chain[1] else null;
        pub const InterfaceType = chain[chain.len - 1];
        pub fn interface(ptr: *Derived) InterfaceType {
            return InterfaceType.__init_chain(ptr, chain[0 .. chain.len - 1], null, null);
        }

        pub fn new(self: *const Derived, allocator: std.mem.Allocator) !InterfaceType {
            const object: *Derived = try allocator.create(Derived);
            object.* = self.*;
            var refcounter: ?*i32 = null;
            if (@hasField(InterfaceType, "__refcount")) {
                refcounter = try allocator.create(i32);
                refcounter.?.* = 1;
            }

            return InterfaceType.__init_chain(object, chain[0 .. chain.len - 1], allocator, refcounter);
        }

        pub fn __destructor(self: *Derived, allocator: std.mem.Allocator) void {
            allocator.destroy(self);
        }
    };
}

/// This is basic inheritance mechanism that allows to derive from a base class
/// `Base` must be an interface type or a struct that is derived from an interface type.
/// `Derived` must be a struct that has a `base` field of type `Base` when `Base` is not an interface.
/// To declare an interface type, use `ConstructInterface` function.
pub fn DeriveFromBase(comptime Base: anytype, comptime Derived: anytype) type {
    comptime if (!@hasDecl(Base, "IsInterface")) { // ensure we have base member
        if (!@hasField(Derived, "base") or !(@FieldType(Derived, "base") == Base)) {
            @compileError("Deriving from a base instead of an interface requires a 'base' field in the derived type.");
        }
        // disallow fields override
        var base: ?type = Base;
        while (base != null) {
            for (std.meta.fields(Derived)) |field| {
                if (@hasField(base.?, field.name) and !std.mem.eql(u8, field.name, "base")) {
                    @compileError("Field already exists in the base: " ++ field.name);
                }
            }
            base = base.?.Base;
        }
    };
    return struct {
        pub usingnamespace DeriveFromChain(build_inheritance_chain(Base, Derived), Derived);
    };
}

/// This is a wrapper to delegate virtual calls to the vtable.
/// Look into 'examples' for usage examples.
/// `self` is a pointer to the object that implements the interface.
/// `name` is the name of the method to call.
/// `args` is a tuple of arguments to pass to the method.
/// `ReturnType` is the type of the return value of the method.
pub fn VirtualCall(self: anytype, comptime name: []const u8, args: anytype, ReturnType: type) ReturnType {
    return @field(self.__vtable, name).?(self.__ptr, args);
}

/// This function constructs an interface type.
/// `SelfType` is a type of the interface holder generator function.
/// Returns a struct that represents the interface type.
pub fn ConstructInterface(comptime SelfType: fn (comptime _: type) type) type {
    return struct {
        pub const Self = @This();
        pub const VTable = BuildVTable(SelfType, @This());
        pub const IsInterface = true;
        pub const Base: ?type = null;
        __vtable: *const VTable,
        __ptr: *anyopaque,
        __interface_allocator: ?std.mem.Allocator,

        pub usingnamespace GenerateClass(SelfType(@This()));

        pub fn __destructor(self: *Self) void {
            if (self.__interface_allocator) |allocator| {
                VirtualCall(self, "__destructor", .{allocator}, void);
            }
        }
    };
}

/// This function constructs an reference counting interface type.
/// It is intended for objects that may be shared
/// `SelfType` is a type of the interface holder generator function.
/// Returns a struct that represents the interface type.
pub fn ConstructCountingInterface(comptime SelfType: fn (comptime _: type) type) type {
    return struct {
        pub const Self = @This();
        pub const VTable = BuildVTable(SelfType, @This());
        pub const IsInterface = true;
        pub const Base: ?type = null;
        __vtable: *const VTable,
        __ptr: *anyopaque,
        __interface_allocator: ?std.mem.Allocator,
        __refcount: ?*i32,

        pub usingnamespace GenerateClass(SelfType(@This()));

        pub fn __destructor(self: *Self) void {
            if (self.__interface_allocator) |allocator| {
                self.__refcount.?.* -= 1;
                if (self.__refcount.?.* == 0) {
                    VirtualCall(self, "__destructor", .{allocator}, void);
                    allocator.destroy(self.__refcount.?);
                }
            }
        }

        pub fn share(self: *Self) Self {
            if (self.__refcount) |r| {
                r.* += 1;
            }
            return self.*;
        }
    };
}

pub fn DestructorCall(self: anytype) void {
    self.__destructor();
}
