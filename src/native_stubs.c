#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/osdeps.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <caml/custom.h>

#define SHARING (FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
static void win_error(const char *op, DWORD error) {
  char msg[256]; snprintf(msg,sizeof msg,"%s: Windows error %lu",op,(unsigned long)error);
  caml_failwith(msg);
}
static wchar_t *wide(value p) {
  if (memchr(String_val(p),0,caml_string_length(p))) caml_invalid_argument("NUL in pathname");
  return caml_stat_strdup_to_utf16(String_val(p));
}
static HANDLE open_path(const wchar_t *p,DWORD access) {
  return CreateFileW(p,access,SHARING,NULL,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,NULL);
}
CAMLprim value fm_absolute(value path) {
  CAMLparam1(path); CAMLlocal1(result);
  wchar_t *p=wide(path); DWORD n=GetFullPathNameW(p,0,NULL,NULL);
  if (!n) { DWORD e=GetLastError(); caml_stat_free(p); win_error("GetFullPathName",e); }
  wchar_t *buf=caml_stat_alloc((n+1)*sizeof(wchar_t));
  DWORD got=GetFullPathNameW(p,n+1,buf,NULL); caml_stat_free(p);
  if (!got || got>n) { DWORD e=GetLastError(); caml_stat_free(buf); win_error("GetFullPathName",e); }
  result=caml_copy_string_of_utf16(buf); caml_stat_free(buf); CAMLreturn(result);
}
CAMLprim value fm_canonical(value path) {
  CAMLparam1(path); CAMLlocal1(result);
  wchar_t *p=wide(path); HANDLE h=open_path(p,0); caml_stat_free(p);
  if (h==INVALID_HANDLE_VALUE) win_error("Canonical open",GetLastError());
  DWORD n=GetFinalPathNameByHandleW(h,NULL,0,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  if (!n) { DWORD e=GetLastError(); CloseHandle(h); win_error("Canonical name",e); }
  wchar_t *buf=caml_stat_alloc((n+1)*sizeof(wchar_t));
  DWORD got=GetFinalPathNameByHandleW(h,buf,n+1,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
  DWORD e=GetLastError(); CloseHandle(h);
  if (!got || got>n) { caml_stat_free(buf); win_error("Canonical name",e); }
  /* Retain the extended-length prefix, including for UNC names. */
  while (got>7 && buf[got-1]==L'\\') buf[--got]=0;
  result=caml_copy_string_of_utf16(buf); caml_stat_free(buf); CAMLreturn(result);
}
CAMLprim value fm_key(value path) {
  CAMLparam1(path); CAMLlocal1(result);
  wchar_t *p=wide(path);
  for (wchar_t *c=p;*c;c++) if (*c==L'/') *c=L'\\';
  int n=LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_UPPERCASE,p,-1,NULL,0,NULL,NULL,0);
  if (!n) { caml_stat_free(p); win_error("Case folding",GetLastError()); }
  wchar_t *buf=caml_stat_alloc(n*sizeof(wchar_t));
  if (!LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_UPPERCASE,p,-1,buf,n,NULL,NULL,0)) {
    DWORD e=GetLastError(); caml_stat_free(p); caml_stat_free(buf); win_error("Case folding",e);
  }
  caml_stat_free(p); result=caml_copy_string_of_utf16(buf); caml_stat_free(buf); CAMLreturn(result);
}
CAMLprim value fm_attributes(value path) {
  CAMLparam1(path); CAMLlocal3(some,record,size);
  wchar_t *p=wide(path); WIN32_FILE_ATTRIBUTE_DATA a;
  BOOL ok=GetFileAttributesExW(p,GetFileExInfoStandard,&a); DWORD e=GetLastError(); caml_stat_free(p);
  if (!ok) { if(e==ERROR_FILE_NOT_FOUND || e==ERROR_PATH_NOT_FOUND) CAMLreturn(Val_none); win_error("Attributes",e); }
  size=caml_copy_int64(((int64_t)a.nFileSizeHigh<<32)|a.nFileSizeLow);
  record=caml_alloc_tuple(3);
  Store_field(record,0,Val_bool(a.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY));
  Store_field(record,1,Val_bool(a.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT));
  Store_field(record,2,size); some=caml_alloc_small(1,0); Field(some,0)=record; CAMLreturn(some);
}
CAMLprim value fm_identity(value path) {
  CAMLparam1(path);
  wchar_t *p=wide(path); HANDLE h=open_path(p,0); caml_stat_free(p);
  if(h==INVALID_HANDLE_VALUE) win_error("Identity open",GetLastError());
  FILE_ID_INFO info;
  BOOL ok=GetFileInformationByHandleEx(h,FileIdInfo,&info,sizeof info); DWORD e=GetLastError(); CloseHandle(h);
  if(!ok) win_error("Stable file identity unavailable",e);
  char s[64]; int at=snprintf(s,sizeof s,"%016llx:",(unsigned long long)info.VolumeSerialNumber);
  for(int i=0;i<16;i++) at+=snprintf(s+at,sizeof(s)-at,"%02x",info.FileId.Identifier[i]);
  CAMLreturn(caml_copy_string(s));
}
typedef struct { HANDLE handle; WIN32_FIND_DATAW data; int first; } directory;
CAMLprim value fm_open_dir(value path) {
  CAMLparam1(path); CAMLlocal1(result);
  wchar_t *p=wide(path); size_t n=wcslen(p);
  wchar_t *pattern=caml_stat_alloc((n+3)*sizeof(wchar_t));
  memcpy(pattern,p,n*sizeof(wchar_t));
  if(n && p[n-1]!=L'\\') pattern[n++]=L'\\';
  pattern[n]=L'*'; pattern[n+1]=0; caml_stat_free(p);
  directory *d=caml_stat_alloc(sizeof *d);
  d->handle=FindFirstFileExW(pattern,FindExInfoBasic,&d->data,FindExSearchNameMatch,NULL,FIND_FIRST_EX_LARGE_FETCH);
  DWORD e=GetLastError(); caml_stat_free(pattern); d->first=1;
  if(d->handle==INVALID_HANDLE_VALUE && e!=ERROR_FILE_NOT_FOUND) { caml_stat_free(d); win_error("Enumerate directory",e); }
  result=caml_copy_nativeint((intnat)d); CAMLreturn(result);
}
CAMLprim value fm_next(value dir) {
  CAMLparam1(dir); CAMLlocal2(s,result);
  directory *d=(directory*)Nativeint_val(dir);
  if(d->handle==INVALID_HANDLE_VALUE) CAMLreturn(Val_none);
  for(;;) {
    if(d->first) d->first=0;
    else if(!FindNextFileW(d->handle,&d->data)) {
      DWORD e=GetLastError(); if(e==ERROR_NO_MORE_FILES) CAMLreturn(Val_none); win_error("Enumerate next",e);
    }
    if(wcscmp(d->data.cFileName,L".") && wcscmp(d->data.cFileName,L"..")) break;
  }
  s=caml_copy_string_of_utf16(d->data.cFileName); result=caml_alloc_small(1,0); Field(result,0)=s; CAMLreturn(result);
}
CAMLprim value fm_close_dir(value dir) {
  directory *d=(directory*)Nativeint_val(dir);
  if(d->handle!=INVALID_HANDLE_VALUE) FindClose(d->handle);
  caml_stat_free(d); return Val_unit;
}
/* Access-only preflight; never creates a probe file in plan mode.
   0 read file; 1 read+delete source; 2 create/delete children; 3 prune dir. */
CAMLprim value fm_probe(value path,value mode) {
  CAMLparam2(path,mode); wchar_t *p=wide(path); int m=Int_val(mode);
  DWORD a=GetFileAttributesW(p), e=GetLastError();
  if(a==INVALID_FILE_ATTRIBUTES) { caml_stat_free(p); win_error("Preflight attributes",e); }
  if(m==1 && (a&(FILE_ATTRIBUTE_READONLY|FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))) {
    caml_stat_free(p); caml_failwith("Preflight: source is readonly, a link, or not a regular file");
  }
  DWORD access=m==0?GENERIC_READ:m==1?(GENERIC_READ|DELETE):m==2?
    (FILE_ADD_FILE|FILE_ADD_SUBDIRECTORY|FILE_LIST_DIRECTORY):(DELETE|FILE_LIST_DIRECTORY);
  HANDLE h=open_path(p,access); e=GetLastError(); caml_stat_free(p);
  if(h==INVALID_HANDLE_VALUE) win_error("Preflight access/sharing",e);
  if(m<2 && GetFileType(h)!=FILE_TYPE_DISK) { CloseHandle(h); caml_failwith("Not a regular disk file"); }
  /* Byte-range locks may allow CreateFile but prevent subsequent reads. */
  if(m<2) {
    OVERLAPPED ov={0};
    if(!LockFileEx(h,LOCKFILE_FAIL_IMMEDIATELY,0,MAXDWORD,MAXDWORD,&ov)) {
      e=GetLastError(); CloseHandle(h); win_error("Preflight file lock",e);
    }
    UnlockFileEx(h,0,MAXDWORD,MAXDWORD,&ov);
  }
  CloseHandle(h); CAMLreturn(Val_unit);
}
/* One reusable buffer/provider per domain, explicitly released at pool shutdown.
   The custom finalizer is a backup for exceptional construction/GC paths. */
typedef struct { unsigned char *buffer; BCRYPT_ALG_HANDLE algorithm; } hash_context;
static void hash_context_close(value v) {
  hash_context *c=Data_custom_val(v);
  free(c->buffer); c->buffer=NULL;
  if(c->algorithm) BCryptCloseAlgorithmProvider(c->algorithm,0);
  c->algorithm=NULL;
}
static struct custom_operations hash_ops = {
  "folder_merge.hash_context",hash_context_close,custom_compare_default,
  custom_hash_default,custom_serialize_default,custom_deserialize_default,
  custom_compare_ext_default,custom_fixed_length_default
};
CAMLprim value fm_hash_context(value unit) {
  CAMLparam1(unit); CAMLlocal1(v);
  v=caml_alloc_custom(&hash_ops,sizeof(hash_context),1024*1024,8*1024*1024);
  hash_context *c=Data_custom_val(v); c->buffer=NULL; c->algorithm=NULL;
  c->buffer=malloc(1024*1024); if(!c->buffer) caml_raise_out_of_memory();
  if(BCryptOpenAlgorithmProvider(&c->algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0) {
    hash_context_close(v); caml_failwith("Cannot initialize Windows SHA-256 provider");
  }
  CAMLreturn(v);
}
CAMLprim value fm_hash_context_close(value context) { hash_context_close(context); return Val_unit; }
/* CNG hashes in a 1 MiB native buffer; no OCaml allocation per block. */
CAMLprim value fm_hash(value context,value path) {
  CAMLparam2(context,path); CAMLlocal1(result);
  hash_context *c=Data_custom_val(context);
  unsigned char *buf=c->buffer; BCRYPT_ALG_HANDLE alg=c->algorithm;
  if(!buf || !alg) caml_failwith("Closed hash context");
  wchar_t *p=wide(path); unsigned char digest[32]; DWORD error=0;
  caml_enter_blocking_section();
  HANDLE h=CreateFileW(p,GENERIC_READ,SHARING,NULL,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,NULL);
  BCRYPT_HASH_HANDLE hash=NULL;
  if(h==INVALID_HANDLE_VALUE) { error=GetLastError(); goto finish; }
  if(BCryptCreateHash(alg,&hash,NULL,0,NULL,0,0)<0) { error=ERROR_INTERNAL_ERROR; goto finish; }
  for(;;) {
    DWORD n=0; if(!ReadFile(h,buf,1024*1024,&n,NULL)) { error=GetLastError(); break; }
    if(!n) break;
    if(BCryptHashData(hash,buf,n,0)<0) { error=ERROR_INTERNAL_ERROR; break; }
  }
  if(!error && BCryptFinishHash(hash,digest,32,0)<0) error=ERROR_INTERNAL_ERROR;
finish:
  if(hash) BCryptDestroyHash(hash);
  if(h!=INVALID_HANDLE_VALUE) CloseHandle(h);
  caml_leave_blocking_section(); caml_stat_free(p);
  if(error) win_error("SHA-256 read",error);
  result=caml_alloc_initialized_string(32,(char*)digest); CAMLreturn(result);
}
CAMLprim value fm_mkdir(value path) {
  CAMLparam1(path); wchar_t *p=wide(path); BOOL ok=CreateDirectoryW(p,NULL); DWORD e=GetLastError();
  caml_stat_free(p); if(!ok) win_error("Create directory",e); CAMLreturn(Val_unit);
}
CAMLprim value fm_remove_dir(value path) {
  CAMLparam1(path); wchar_t *p=wide(path); BOOL ok=RemoveDirectoryW(p); DWORD e=GetLastError(); caml_stat_free(p);
  if(!ok && e!=ERROR_DIR_NOT_EMPTY) win_error("Prune directory",e);
  CAMLreturn(Val_bool(ok));
}
CAMLprim value fm_rename(value source,value dest) {
  CAMLparam2(source,dest); wchar_t *s=wide(source),*d=wide(dest);
  /* Neither REPLACE_EXISTING nor COPY_ALLOWED: cannot overwrite or silently copy. */
  BOOL ok=MoveFileExW(s,d,MOVEFILE_WRITE_THROUGH); DWORD e=GetLastError();
  caml_stat_free(s); caml_stat_free(d);
  if(!ok && e!=ERROR_NOT_SAME_DEVICE) win_error("No-replace rename",e);
  CAMLreturn(Val_bool(ok));
}
CAMLprim value fm_copy(value source,value dest) {
  CAMLparam2(source,dest); wchar_t *s=wide(source),*d=wide(dest); DWORD error=0;
  caml_enter_blocking_section();
  /* CopyFile preserves alternate streams, attributes and security where supported. */
  if(!CopyFileW(s,d,TRUE)) error=GetLastError();
  if(!error) {
    HANDLE h=CreateFileW(d,GENERIC_WRITE,SHARING,NULL,OPEN_EXISTING,0,NULL);
    if(h==INVALID_HANDLE_VALUE) error=GetLastError();
    else { if(!FlushFileBuffers(h)) error=GetLastError(); CloseHandle(h); }
  }
  caml_leave_blocking_section(); caml_stat_free(s); caml_stat_free(d);
  if(error) win_error("Copy/flush",error);
  CAMLreturn(Val_unit);
}
CAMLprim value fm_unlink(value path) {
  CAMLparam1(path); wchar_t *p=wide(path); BOOL ok=DeleteFileW(p); DWORD e=GetLastError(); caml_stat_free(p);
  if(!ok) win_error("Remove source",e);
  CAMLreturn(Val_unit);
}
CAMLprim value fm_free_space(value path) {
  CAMLparam1(path); wchar_t *p=wide(path); ULARGE_INTEGER n;
  BOOL ok=GetDiskFreeSpaceExW(p,&n,NULL,NULL); DWORD e=GetLastError(); caml_stat_free(p);
  if(!ok) win_error("Free space",e);
  CAMLreturn(caml_copy_int64(n.QuadPart));
}
CAMLprim value fm_volume(value path) {
  CAMLparam1(path); wchar_t *p=wide(path); HANDLE h=open_path(p,0); caml_stat_free(p);
  if(h==INVALID_HANDLE_VALUE) win_error("Volume open",GetLastError());
  FILE_ID_INFO i; BOOL ok=GetFileInformationByHandleEx(h,FileIdInfo,&i,sizeof i); DWORD e=GetLastError(); CloseHandle(h);
  if(!ok) win_error("Volume identity",e);
  char b[32]; snprintf(b,sizeof b,"%016llx",(unsigned long long)i.VolumeSerialNumber); CAMLreturn(caml_copy_string(b));
}
CAMLprim value fm_flush(value fd) {
  if(!FlushFileBuffers(Handle_val(fd))) win_error("Journal flush",GetLastError());
  return Val_unit;
}
CAMLprim value fm_required_space(value source,value destination) {
  CAMLparam2(source,destination); wchar_t *s=wide(source), *d=wide(destination);
  wchar_t root[32768]; DWORD sectors,bytes,free_clusters,total_clusters;
  if(!GetVolumePathNameW(d,root,32768) || !GetDiskFreeSpaceW(root,&sectors,&bytes,&free_clusters,&total_clusters)) {
    DWORD e=GetLastError(); caml_stat_free(s); caml_stat_free(d); win_error("Allocation unit",e);
  }
  caml_stat_free(d);
  uint64_t unit=(uint64_t)sectors*bytes; if(unit<65536) unit=65536;
  WIN32_FIND_STREAM_DATA stream;
  HANDLE h=FindFirstStreamW(s,FindStreamInfoStandard,&stream,0); DWORD e=GetLastError(); caml_stat_free(s);
  uint64_t total=65536;
  if(h==INVALID_HANDLE_VALUE) {
    if(e!=ERROR_HANDLE_EOF) win_error("Stream space enumeration",e);
  } else {
    for(;;) {
      uint64_t size=stream.StreamSize.QuadPart;
      if(size>INT64_MAX-unit || total>INT64_MAX-((size+unit-1)/unit)*unit) {
        FindClose(h); caml_failwith("Space budget overflow");
      }
      total+=((size+unit-1)/unit)*unit;
      if(!FindNextStreamW(h,&stream)) {
        e=GetLastError(); FindClose(h); if(e!=ERROR_HANDLE_EOF) win_error("Stream space enumeration",e); break;
      }
    }
  }
  CAMLreturn(caml_copy_int64((int64_t)total));
}
CAMLprim value fm_probe_create(value directory_path) {
  CAMLparam1(directory_path); wchar_t *p=wide(directory_path);
  unsigned char random[16];
  if(BCryptGenRandom(NULL,random,sizeof random,BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0) {
    caml_stat_free(p); caml_failwith("Preflight random name generation failed");
  }
  size_t n=wcslen(p); wchar_t *dest=caml_stat_alloc((n+80)*sizeof(wchar_t));
  memcpy(dest,p,n*sizeof(wchar_t)); caml_stat_free(p);
  wcscpy(dest+n,L"\\.folder-merge-probe-"); size_t at=wcslen(dest);
  for(int i=0;i<16;i++) { swprintf(dest+at,3,L"%02x",random[i]); at+=2; }
  HANDLE h=CreateFileW(dest,GENERIC_WRITE|DELETE,0,NULL,CREATE_NEW,
    FILE_ATTRIBUTE_TEMPORARY|FILE_FLAG_DELETE_ON_CLOSE,NULL);
  DWORD e=GetLastError(); caml_stat_free(dest);
  if(h==INVALID_HANDLE_VALUE) win_error("Destination create/delete preflight",e);
  char byte=0; DWORD written=0;
  BOOL ok=WriteFile(h,&byte,1,&written,NULL) && written==1 && FlushFileBuffers(h);
  e=GetLastError(); CloseHandle(h);
  if(!ok) win_error("Destination write preflight",e);
  CAMLreturn(Val_unit);
}
CAMLprim value fm_validate_destination(value path) {
  CAMLparam1(path); wchar_t *p=wide(path); size_t total=wcslen(p),component=0;
  int invalid=total>32680; /* also leave room for a sibling temporary name */
  for(size_t i=0;i<total;i++) {
    if(p[i]==L'\\' || p[i]==L'/') component=0;
    else if(++component>255) invalid=1;
  }
  caml_stat_free(p);
  if(invalid) caml_failwith("Planned destination exceeds Windows path/component limits");
  CAMLreturn(Val_unit);
}
