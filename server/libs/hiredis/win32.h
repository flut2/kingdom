#ifndef _WIN32_HELPER_INCLUDE
#define _WIN32_HELPER_INCLUDE
#ifdef _WIN32

#include <winsock2.h> /* for struct timeval */

#ifndef inline
#define inline __inline
#endif

#ifndef strcasecmp
#define strcasecmp stricmp
#endif

#ifndef strncasecmp
#define strncasecmp strnicmp
#endif

#ifndef va_copy
#define va_copy(d,s) ((d) = (s))
#endif

#ifndef snprintf
#define snprintf _snprintf

#endif
#endif /* _WIN32 */

#ifdef _WIN32
#define strerror_r(errno,buf,len) strerror_s(buf,len,errno)
#endif /* _WIN32 */

#endif /* _WIN32_HELPER_INCLUDE */
