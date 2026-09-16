/* Windows 10+ ships SQLite. Load only the trusted System32 DLL. This narrow
   binding uses the stable SQLite C ABI, and needs no downloaded dependency. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <stdio.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
#define API(ret,name,args) static ret (__cdecl *p_##name) args
API(int,sqlite3_open,(const char*,sqlite3**));
API(int,sqlite3_close,(sqlite3*));
API(int,sqlite3_exec,(sqlite3*,const char*,void*,void*,char**));
API(const char*,sqlite3_errmsg,(sqlite3*));
API(int,sqlite3_prepare_v2,(sqlite3*,const char*,int,sqlite3_stmt**,const char**));
API(int,sqlite3_finalize,(sqlite3_stmt*));
API(int,sqlite3_reset,(sqlite3_stmt*));
API(int,sqlite3_clear_bindings,(sqlite3_stmt*));
API(int,sqlite3_bind_blob,(sqlite3_stmt*,int,const void*,int,void(*)(void*)));
API(int,sqlite3_bind_text,(sqlite3_stmt*,int,const char*,int,void(*)(void*)));
API(int,sqlite3_step,(sqlite3_stmt*));
API(int,sqlite3_column_count,(sqlite3_stmt*));
API(const void*,sqlite3_column_blob,(sqlite3_stmt*,int));
API(int,sqlite3_column_bytes,(sqlite3_stmt*,int));
API(sqlite3*,sqlite3_db_handle,(sqlite3_stmt*));
#define LOAD(name) do { *(FARPROC*)&p_##name=GetProcAddress(lib,#name); if(!p_##name) caml_failwith("Missing " #name); } while(0)
static void load(void) {
  static HMODULE lib=NULL; if(lib) return;
  lib=LoadLibraryExW(L"winsqlite3.dll",NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
  if(!lib) caml_failwith("Windows 10+ winsqlite3.dll is required");
  LOAD(sqlite3_open); LOAD(sqlite3_close); LOAD(sqlite3_exec); LOAD(sqlite3_errmsg);
  LOAD(sqlite3_prepare_v2); LOAD(sqlite3_finalize); LOAD(sqlite3_reset); LOAD(sqlite3_clear_bindings);
  LOAD(sqlite3_bind_blob); LOAD(sqlite3_bind_text); LOAD(sqlite3_step); LOAD(sqlite3_column_count);
  LOAD(sqlite3_column_blob); LOAD(sqlite3_column_bytes); LOAD(sqlite3_db_handle);
}
#define DB(v) ((sqlite3*)Nativeint_val(v))
#define ST(v) ((sqlite3_stmt*)Nativeint_val(v))
CAMLprim value fm_db_open(value path) {
  CAMLparam1(path); load(); sqlite3 *db=NULL;
  if(p_sqlite3_open(String_val(path),&db)!=0) {
    char msg[512]; snprintf(msg,sizeof msg,"SQLite open: %s",db?p_sqlite3_errmsg(db):"allocation failure");
    if(db) p_sqlite3_close(db);
    caml_failwith(msg);
  }
  CAMLreturn(caml_copy_nativeint((intnat)db));
}
CAMLprim value fm_db_close(value db) {
  if(p_sqlite3_close(DB(db))!=0) caml_failwith("SQLite close: outstanding statement");
  return Val_unit;
}
CAMLprim value fm_db_exec(value db,value sql) {
  if(p_sqlite3_exec(DB(db),String_val(sql),NULL,NULL,NULL)!=0) caml_failwith(p_sqlite3_errmsg(DB(db)));
  return Val_unit;
}
CAMLprim value fm_db_prepare(value db,value sql) {
  CAMLparam2(db,sql); sqlite3_stmt *s=NULL;
  if(p_sqlite3_prepare_v2(DB(db),String_val(sql),-1,&s,NULL)!=0) caml_failwith(p_sqlite3_errmsg(DB(db)));
  CAMLreturn(caml_copy_nativeint((intnat)s));
}
CAMLprim value fm_db_finalize(value st) { p_sqlite3_finalize(ST(st)); return Val_unit; }
CAMLprim value fm_db_reset(value st,value args) {
  sqlite3_stmt *s=ST(st); p_sqlite3_reset(s); p_sqlite3_clear_bindings(s);
  for(mlsize_t i=0;i<Wosize_val(args);i++) {
    value a=Field(args,i);
    /* Paths/numbers are text. Binary digests use the distinct blob binding. */
    if(p_sqlite3_bind_text(s,(int)i+1,String_val(a),(int)caml_string_length(a),(void(*)(void*))-1)!=0)
      caml_failwith(p_sqlite3_errmsg(p_sqlite3_db_handle(s)));
  }
  return Val_unit;
}
CAMLprim value fm_db_bind_blob(value st,value index,value bytes) {
  sqlite3_stmt *s=ST(st);
  if(p_sqlite3_bind_blob(s,Int_val(index),String_val(bytes),(int)caml_string_length(bytes),(void(*)(void*))-1)!=0)
    caml_failwith(p_sqlite3_errmsg(p_sqlite3_db_handle(s)));
  return Val_unit;
}
CAMLprim value fm_db_step(value st) {
  CAMLparam1(st); CAMLlocal3(row,result,col); sqlite3_stmt *s=ST(st);
  int r=p_sqlite3_step(s); if(r==101) CAMLreturn(Val_none);
  if(r!=100) caml_failwith(p_sqlite3_errmsg(p_sqlite3_db_handle(s)));
  int n=p_sqlite3_column_count(s); row=caml_alloc(n,0);
  for(int i=0;i<n;i++) {
    const void *p=p_sqlite3_column_blob(s,i); int len=p_sqlite3_column_bytes(s,i);
    col=caml_alloc_initialized_string(len,p?p:""); Store_field(row,i,col);
  }
  result=caml_alloc_small(1,0); Field(result,0)=row; CAMLreturn(result);
}
