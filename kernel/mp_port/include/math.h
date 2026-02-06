#ifndef _MATH_H_SHIM
#define _MATH_H_SHIM

double floor(double x);
double ceil(double x);
double fmod(double x, double y);
double sqrt(double x);
double pow(double base, double exp);
double log(double x);
double exp(double x);
double frexp(double x, int *exp);
double ldexp(double x, int exp);
double modf(double x, double *iptr);
float floorf(float x);

#define HUGE_VAL __builtin_huge_val()
#define NAN __builtin_nanf("")
#define INFINITY __builtin_inff()

static inline int isnan(double x) { return __builtin_isnan(x); }
static inline int isinf(double x) { return __builtin_isinf(x); }
static inline int isfinite(double x) { return __builtin_isfinite(x); }
static inline int signbit(double x) { return __builtin_signbit(x); }
static inline double fabs(double x) { return __builtin_fabs(x); }
static inline double copysign(double x, double y) { return __builtin_copysign(x, y); }
static inline double atan2(double y, double x) { (void)y; (void)x; return 0.0; }
static inline double sin(double x) { (void)x; return 0.0; }
static inline double cos(double x) { (void)x; return 1.0; }
static inline double tan(double x) { (void)x; return 0.0; }
static inline double asin(double x) { (void)x; return 0.0; }
static inline double acos(double x) { (void)x; return 0.0; }
static inline double atan(double x) { (void)x; return 0.0; }
static inline double sinh(double x) { (void)x; return 0.0; }
static inline double cosh(double x) { (void)x; return 1.0; }
static inline double tanh(double x) { (void)x; return 0.0; }
static inline double asinh(double x) { (void)x; return 0.0; }
static inline double acosh(double x) { (void)x; return 0.0; }
static inline double atanh(double x) { (void)x; return 0.0; }
static inline double log2(double x) { (void)x; return 0.0; }
static inline double log10(double x) { (void)x; return 0.0; }
static inline double expm1(double x) { (void)x; return 0.0; }
static inline double log1p(double x) { (void)x; return 0.0; }
static inline double trunc(double x) { return (double)(long long)x; }
static inline double round(double x) { return floor(x + 0.5); }
static inline double remainder(double x, double y) { return fmod(x, y); }
static inline double tgamma(double x) { (void)x; return 1.0; }
static inline double lgamma(double x) { (void)x; return 0.0; }
static inline double erf(double x) { (void)x; return 0.0; }
static inline double erfc(double x) { (void)x; return 1.0; }

#endif
