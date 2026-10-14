# Third-party notices

libre-monitor is built on the following software. The release downloads contain only what is listed under
"Included in the release files".

## Included in the release files

### .NET runtime, WPF and Windows Forms (Windows download)

The Windows download (`LibreMonitor-win-x64.exe`) is a self-contained build: it carries its own copy of the .NET runtime and
the WPF and Windows Forms libraries, so that nothing needs to be installed. They are published by Microsoft and the .NET
Foundation under the MIT licence:

- https://github.com/dotnet/runtime/blob/main/LICENSE.TXT
- https://github.com/dotnet/wpf/blob/main/LICENSE.TXT
- https://github.com/dotnet/winforms/blob/main/LICENSE.TXT

The .NET runtime in turn includes third-party components with their own notices, listed here:
https://github.com/dotnet/runtime/blob/main/THIRD-PARTY-NOTICES.TXT

```
The MIT License (MIT)

Copyright (c) .NET Foundation and Contributors

All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### macOS download

The macOS download (`LibreMonitor-mac.zip`) uses only Apple's system frameworks (AppKit, SwiftUI, Foundation, CryptoKit,
Security, UserNotifications), which come with macOS and are not redistributed.

## Used to build and test, not distributed

- xUnit and Microsoft.NET.Test.Sdk (Apache-2.0 and MIT), for the .NET tests.
- XCTest (part of Apple's toolchain), for the Swift tests.

## Not included

This project contains no code, images or other assets from Abbott. FreeStyle, Libre, LibreLink, LibreLinkUp and LibreView
are trademarks of Abbott, used here only to describe what the software works with.
