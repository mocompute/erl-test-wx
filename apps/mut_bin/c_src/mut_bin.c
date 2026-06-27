/*
mut_bin: Mutable binary NIF for Erlang
Copyright (C) 2026 Mo Omid

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/
#include <erl_nif.h>

ErlNifResourceType *resource_type_unmanaged;
ERL_NIF_TERM atom_ok;
ERL_NIF_TERM atom_error;
ERL_NIF_TERM atom_out_of_memory;
ERL_NIF_TERM atom_out_of_bounds;

typedef struct {
    void* ptr;
    size_t size;
} binary_resource;


static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    // sanity check sizes: ErlNifUInt64 must be large enough for C pointers and sizes
    if (sizeof(ErlNifUInt64) < sizeof(void*)) return 1;
    if (sizeof(ErlNifUInt64) < sizeof(size_t)) return 1;

    resource_type_unmanaged = enif_open_resource_type(env, "mut_bin", "mut_bin", NULL, ERL_NIF_RT_CREATE, NULL);
    if (NULL == resource_type_unmanaged) return 1;

    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    atom_out_of_memory = enif_make_atom(env, "out_of_memory");
    atom_out_of_bounds = enif_make_atom(env, "out_of_bounds");

    return 0;
}

static ERL_NIF_TERM error_oom(ErlNifEnv* env) {
    return enif_make_tuple2(env, atom_error, atom_out_of_memory);
}

static ERL_NIF_TERM error_out_of_bounds(ErlNifEnv* env) {
    return enif_make_tuple2(env, atom_error, atom_out_of_bounds);
}


static ERL_NIF_TERM alloc(ErlNifEnv* env, int argc, ERL_NIF_TERM const argv[]) {
    if (1 != argc) return enif_make_badarg(env);

    ErlNifUInt64 size = 0;
    if (!enif_get_uint64(env, argv[0], &size)) return enif_make_badarg(env);

    void* ptr = enif_alloc((size_t)size);
    if (NULL == ptr) return error_oom(env);

    binary_resource* resource = enif_alloc_resource(resource_type_unmanaged, sizeof(binary_resource));
    if (NULL == resource) return error_oom(env);
    resource->ptr = ptr;
    resource->size = size;
    return enif_make_tuple2(env, atom_ok, enif_make_resource(env, resource));
}

static ERL_NIF_TERM dealloc(ErlNifEnv* env, int argc, ERL_NIF_TERM const argv[]) {
    if (1 != argc) return enif_make_badarg(env);

    binary_resource* resource = NULL;
    if (!enif_get_resource(env, argv[0], resource_type_unmanaged, (void**)&resource)) return enif_make_badarg(env);

    enif_free(resource->ptr);
    enif_release_resource(resource);
    return atom_ok;
}

static ERL_NIF_TERM data(ErlNifEnv* env, int argc, ERL_NIF_TERM const argv[]) {
    if (1 != argc) return enif_make_badarg(env);

    binary_resource* resource = NULL;
    if (!enif_get_resource(env, argv[0], resource_type_unmanaged, (void**)&resource)) return enif_make_badarg(env);

    ErlNifUInt64 offset = (ErlNifUInt64) resource->ptr;
    ErlNifUInt64 size = (ErlNifUInt64) resource->size;
    return enif_make_tuple2(env, enif_make_uint64(env, offset), enif_make_uint64(env, size));
}

static ERL_NIF_TERM copy(ErlNifEnv* env, int argc, ERL_NIF_TERM const argv[]) {
    // copy(dst, dst_offset, src, src_offset, count) where src may be mut_bin or erlang binary
    if (5 != argc) return enif_make_badarg(env);

    binary_resource* resource = NULL;     // argv[0]
    ErlNifUInt64 dst_offset = 0;          // argv[1]
    ErlNifBinary src_bin = {0};           // argv[2], or
    binary_resource* src_resource = NULL; // argv[2]
    ErlNifUInt64 src_offset = 0;          // argv[3]
    ErlNifUInt64 count = 0;               // argv[4]

    void* dst_data = NULL;
    size_t dst_size = 0;
    void* src_data = NULL;
    size_t src_size = 0;

    // argv[0]: resource
    if (!enif_get_resource(env, argv[0], resource_type_unmanaged, (void**)&resource)) return enif_make_badarg(env);
    dst_size = resource->size;
    dst_data = resource->ptr;

    // argv[1]: dst_offset
    if (!enif_get_uint64(env, argv[1], &dst_offset)) return enif_make_badarg(env);

    // argv[3]: src_offset
    if (!enif_get_uint64(env, argv[3], &src_offset)) return enif_make_badarg(env);

    // argv[4]: count
    if (!enif_get_uint64(env, argv[4], &count)) return enif_make_badarg(env);

    /* argv[2]: erlang binary? */
    if (enif_inspect_binary(env, argv[2], &src_bin)) {
        src_size = src_bin.size;
        src_data = src_bin.data;
    } else if (enif_get_resource(env, argv[2], resource_type_unmanaged, (void**)&src_resource)) {
        src_size = src_resource->size;
        src_data = src_resource->ptr;
    }

    if (dst_offset >= dst_size) return error_out_of_bounds(env); // range error
    if (src_offset >= src_size) return error_out_of_bounds(env);

    if (dst_offset + count > dst_size) return error_out_of_bounds(env); // no room in dst
    if (src_offset + count > src_size) return error_out_of_bounds(env); // not enough data in src

    memcpy((unsigned char*)dst_data + dst_offset, (unsigned char*)src_data + src_offset, count);
    return atom_ok;
}

static ERL_NIF_TERM to_erl(ErlNifEnv* env, int argc, ERL_NIF_TERM const argv[]) {
    if (1 != argc) return enif_make_badarg(env);

    binary_resource* resource = NULL;
    if (!enif_get_resource(env, argv[0], resource_type_unmanaged, (void**)&resource)) return enif_make_badarg(env);

    ERL_NIF_TERM out;
    unsigned char* data = enif_make_new_binary(env, resource->size, &out);
    if (NULL == data) return error_oom(env);

    memcpy(data, resource->ptr, resource->size);
    return out;
}


static ErlNifFunc nif_funcs[] = {
    {"alloc", 1, alloc},
    {"dealloc", 1, dealloc},
    {"data", 1, data},
    {"copy", 5, copy},
    {"to_erl", 1, to_erl},
};

ERL_NIF_INIT(mut_bin, nif_funcs, load, NULL, NULL, NULL);
