# std::cout, std::wcout

```c
extern std::ostream cout;
```

```c
extern std::wostream wcout;
```

The global objects `std::cout` and `std::wcout` control output to a stream buffer of implementation-defined type (derived from [`std::streambuf`](devdocs://cpp/io/basic_streambuf)), associated with the standard C output stream [`stdout`](devdocs://cpp/io/c/std_streams).

These objects are guaranteed to be initialized during or before the first time an object of type [`std::ios_base::Init`](devdocs://cpp/io/ios_base/init) is constructed and are available for use in the constructors and destructors of static objects with [ordered initialization](devdocs://cpp/language/initialization#Non-local_variables) (as long as [`<iostream>`](devdocs://cpp/header/iostream) is included before the object is defined).

Unless `std::ios_base::sync_with_stdio(false)` has been issued, it is safe to concurrently access these objects from multiple threads for both formatted and unformatted output.

By specification of [`std::cin`](devdocs://cpp/io/cin), `std::cin.tie()` returns `&std::cout`. This means that any input operation on `std::cin` executes `std::cout.flush()` (via [`std::basic_istream::sentry`](devdocs://cpp/io/basic_istream/sentry)'s constructor). Similarly, `std::wcin.tie()` returns `&std::wcout`.

By specification of [`std::cerr`](devdocs://cpp/io/cerr), `std::cerr.tie()` returns `&std::cout`. This means that any output operation on `std::cerr` executes `std::cout.flush()` (via [`std::basic_ostream::sentry`](devdocs://cpp/io/basic_ostream/sentry)'s constructor). Similarly, `std::wcerr.tie()` returns `&std::wcout`. (since C++11)

### Notes

The 'c' in the name refers to "character" ([stroustrup.com FAQ](https://www.stroustrup.com/bs_faq2.html#cout)); `cout` means "character output" and `wcout` means "wide character output".

Because [dynamic initialization](devdocs://cpp/language/initialization#Dynamic_initialization) of [templated](devdocs://cpp/language/templates#Templated_entity) variables are unordered, it is not guaranteed that `std::cout` has been initialized to a usable state before the initialization of such variables begins, unless an object of type [`std::ios_base::Init`](devdocs://cpp/io/ios_base/init) has been constructed.

### Example

```c
#include <iostream>

struct Foo
{
    int n;
    Foo()
    {
        std::cout << "static constructor\n";
    }
    ~Foo()
    {
        std::cout << "static destructor\n";
    }
};

Foo f; // static object

int main()
{
    std::cout << "main function\n";
}
```

Output:

```c
static constructor
main function
static destructor
```

### See also

| Init              | initializes standard stream objects (public member class of `std::ios_base`)                                                                                                                           |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| cerrwcerr         | writes to the standard C error stream `stderr`, unbuffered (global object)                                                                                                                             |
| clogwclog         | writes to the standard C error stream `stderr` (global object)                                                                                                                                         |
| stdinstdoutstderr | expression of type FILE* associated with the input stream expression of type FILE* associated with the output stream expression of type FILE* associated with the error output stream (macro constant) |

© cppreference.com
Licensed under the Creative Commons Attribution-ShareAlike Unported License v3.0.
[https://en.cppreference.com/cpp/io/cout](https://en.cppreference.com/cpp/io/cout)
