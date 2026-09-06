// CursorImageTest.cpp : 定义应用程序的入口点。
//

#include "framework.h"
#include "CursorImageTest.h"
#include "CursorMonitor.h"

#define MAX_LOADSTRING 100

// 全局变量:
HINSTANCE hInst;                                // 当前实例
WCHAR szTitle[MAX_LOADSTRING];                  // 标题栏文本
WCHAR szWindowClass[MAX_LOADSTRING];            // 主窗口类名

// 此代码模块中包含的函数的前向声明:
ATOM                MyRegisterClass(HINSTANCE hInstance);
BOOL                InitInstance(HINSTANCE, int);
LRESULT CALLBACK    WndProc(HWND, UINT, WPARAM, LPARAM);
INT_PTR CALLBACK    About(HWND, UINT, WPARAM, LPARAM);

int APIENTRY wWinMain(_In_ HINSTANCE hInstance,
                     _In_opt_ HINSTANCE hPrevInstance,
                     _In_ LPWSTR    lpCmdLine,
                     _In_ int       nCmdShow)
{
    UNREFERENCED_PARAMETER(hPrevInstance);
    UNREFERENCED_PARAMETER(lpCmdLine);

    // TODO: 在此处放置代码。

    // 初始化全局字符串
    LoadStringW(hInstance, IDS_APP_TITLE, szTitle, MAX_LOADSTRING);
    LoadStringW(hInstance, IDC_CURSORIMAGETEST, szWindowClass, MAX_LOADSTRING);
    MyRegisterClass(hInstance);

    // 执行应用程序初始化:
    if (!InitInstance (hInstance, nCmdShow))
    {
        return FALSE;
    }

    HACCEL hAccelTable = LoadAccelerators(hInstance, MAKEINTRESOURCE(IDC_CURSORIMAGETEST));

    MSG msg;

    // 主消息循环:
    while (GetMessage(&msg, nullptr, 0, 0))
    {
        if (!TranslateAccelerator(msg.hwnd, hAccelTable, &msg))
        {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }

    return (int) msg.wParam;
}



//
//  函数: MyRegisterClass()
//
//  目标: 注册窗口类。
//
ATOM MyRegisterClass(HINSTANCE hInstance)
{
    WNDCLASSEXW wcex;

    wcex.cbSize = sizeof(WNDCLASSEX);

    wcex.style          = CS_HREDRAW | CS_VREDRAW;
    wcex.lpfnWndProc    = WndProc;
    wcex.cbClsExtra     = 0;
    wcex.cbWndExtra     = 0;
    wcex.hInstance      = hInstance;
    wcex.hIcon          = LoadIcon(hInstance, MAKEINTRESOURCE(IDI_CURSORIMAGETEST));
    wcex.hCursor        = LoadCursor(nullptr, IDC_ARROW);
    wcex.hbrBackground  = (HBRUSH)(COLOR_WINDOW+1);
    wcex.lpszMenuName   = MAKEINTRESOURCEW(IDC_CURSORIMAGETEST);
    wcex.lpszClassName  = szWindowClass;
    wcex.hIconSm        = LoadIcon(wcex.hInstance, MAKEINTRESOURCE(IDI_SMALL));

    return RegisterClassExW(&wcex);
}

//
//   函数: InitInstance(HINSTANCE, int)
//
//   目标: 保存实例句柄并创建主窗口
//
//   注释:
//
//        在此函数中，我们在全局变量中保存实例句柄并
//        创建和显示主程序窗口。
//

bool test_endian(void) {
    int test_var = 1;
    unsigned char* test_endian = reinterpret_cast<unsigned char*>(&test_var);
    return (test_endian[0] == 0);  // 返回true表示小端序，false表示大端序
}

void ConvertUint8ToUint32(const std::vector<uint8_t>& inputArray,
    uint32_t& width,
    uint32_t& height,
    uint32_t& hotx,
    uint32_t& hoty,
    uint32_t& hash,
    std::vector<uint32_t>& outputArray) {
    // 用于读取数组位置
    size_t index = 0;

    // 第一个字节是标识符，这里是0，跳过它
    index += 1;

    // 解析宽度
    width = 0;
    uint8_t wBytes[sizeof(uint32_t)];
    if (test_endian()) {
        // 小端序
        for (size_t i = 0; i < sizeof(uint32_t); ++i) {
            wBytes[i] = inputArray[index++];
        }
    }
    else {
        // 大端序
        for (size_t i = sizeof(uint32_t); i > 0; --i) {
            wBytes[i - 1] = inputArray[index++];
        }
    }
    std::memcpy(&width, wBytes, sizeof(uint32_t));

    // 解析高度
    height = 0;
    uint8_t hBytes[sizeof(uint32_t)];
    if (test_endian()) {
        // 小端序
        for (size_t i = 0; i < sizeof(uint32_t); ++i) {
            hBytes[i] = inputArray[index++];
        }
    }
    else {
        // 大端序
        for (size_t i = sizeof(uint32_t); i > 0; --i) {
            hBytes[i - 1] = inputArray[index++];
        }
    }
    std::memcpy(&height, hBytes, sizeof(uint32_t));

    // 解析 hotx
    hotx = 0;
    uint8_t hxBytes[sizeof(uint32_t)];
    if (test_endian()) {
        for (size_t i = 0; i < sizeof(uint32_t); ++i) {
            hxBytes[i] = inputArray[index++];
        }
    }
    else {
        for (size_t i = sizeof(uint32_t); i > 0; --i) {
            hxBytes[i - 1] = inputArray[index++];
        }
    }
    std::memcpy(&hotx, hxBytes, sizeof(uint32_t));

    // 解析 hoty
    hoty = 0;
    uint8_t hyBytes[sizeof(uint32_t)];
    if (test_endian()) {
        for (size_t i = 0; i < sizeof(uint32_t); ++i) {
            hyBytes[i] = inputArray[index++];
        }
    }
    else {
        for (size_t i = sizeof(uint32_t); i > 0; --i) {
            hyBytes[i - 1] = inputArray[index++];
        }
    }
    std::memcpy(&hoty, hyBytes, sizeof(uint32_t));

    // 解析 hash
    hash = 0;
    uint8_t hashBytes[sizeof(uint32_t)];
    if (test_endian()) {
        for (size_t i = 0; i < sizeof(uint32_t); ++i) {
            hashBytes[i] = inputArray[index++];
        }
    }
    else {
        for (size_t i = sizeof(uint32_t); i > 0; --i) {
            hashBytes[i - 1] = inputArray[index++];
        }
    }
    std::memcpy(&hash, hashBytes, sizeof(uint32_t));

    // 解析 uint32_t 数组
    outputArray.resize(width * height);
    for (size_t i = 0; i < width * height; ++i) {
        uint32_t value = 0;
        uint8_t bytes[sizeof(uint32_t)];

        if (test_endian()) {
            for (size_t j = sizeof(uint32_t); j > 0; --j) {
                bytes[j - 1] = inputArray[index++];
            }
        }
        else {
            for (size_t j = 0; j < sizeof(uint32_t); ++j) {
                bytes[j] = inputArray[index++];
            }
        }

        std::memcpy(&value, bytes, sizeof(uint32_t));
        outputArray[i] = value;
    }
}

HWND hWnd;

void DrawBufferToHWND(const uint32_t* buffer,
    int width,
    int height,
    HWND hWnd) {
    HDC hdc = GetDC(hWnd);

    HDC memDC = CreateCompatibleDC(hdc);
    if (memDC == NULL) {
        ReleaseDC(hWnd, hdc);
        return;
    }

    HBITMAP hBitmap = CreateCompatibleBitmap(hdc, width, height);
    if (hBitmap == NULL) {
        DeleteDC(memDC);
        ReleaseDC(hWnd, hdc);
        return;
    }
    HBITMAP hOldBitmap = (HBITMAP)SelectObject(memDC, hBitmap);


    HBRUSH blueBrush = CreateSolidBrush(RGB(0, 0, 255));
    RECT rect = { 0, 0, width, height };
    FillRect(memDC, &rect, blueBrush);
    DeleteObject(blueBrush);

    BITMAPINFO bmi = { 0 };
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    SetDIBits(memDC, hBitmap, 0, height, buffer, &bmi, DIB_RGB_COLORS);

    BitBlt(hdc, 0, 0, width, height, memDC, 0, 0, SRCCOPY);

    SelectObject(memDC, hOldBitmap);
    DeleteObject(hBitmap);
    DeleteDC(memDC);
    ReleaseDC(hWnd, hdc);
}

BOOL InitInstance(HINSTANCE hInstance, int nCmdShow)
{
   hInst = hInstance; // 将实例句柄存储在全局变量中

   hWnd = CreateWindowW(szWindowClass, szTitle, WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT, 0, CW_USEDEFAULT, 0, nullptr, nullptr, hInstance, nullptr);

   if (!hWnd)
   {
      return FALSE;
   }

   ShowWindow(hWnd, nCmdShow);
   UpdateWindow(hWnd);

   CursorMonitor::startHook([](int message, int msg_info, const std::vector<uint8_t>& bytes) {
       int b;
       switch (message) {
       case CPP_CURSOR_INVISIBLE:
           b = 0;
           break;
       case CPP_CURSOR_VISIBLE:
           b = 0;
           break;
       case CPP_CURSOR_UPDATED_DEFAULT:
           b = 0;
           break;
       case CPP_CURSOR_UPDATED_IMAGE:
       {
           uint32_t width, height, hotX, hotY, hash;
           std::vector<uint32_t> imageData;
           ConvertUint8ToUint32(bytes, width, height, hotX, hotY, hash, imageData);
           DrawBufferToHWND(&imageData[0], width, height, hWnd);
           break;
       }
       case CPP_CURSOR_UPDATED_CACHED:
           b = 0;
           break;
       }
   }, 1, true, 1.0f);

   return TRUE;
}

//
//  函数: WndProc(HWND, UINT, WPARAM, LPARAM)
//
//  目标: 处理主窗口的消息。
//
//  WM_COMMAND  - 处理应用程序菜单
//  WM_PAINT    - 绘制主窗口
//  WM_DESTROY  - 发送退出消息并返回
//
//
LRESULT CALLBACK WndProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_COMMAND:
        {
            int wmId = LOWORD(wParam);
            // 分析菜单选择:
            switch (wmId)
            {
            case IDM_ABOUT:
                DialogBox(hInst, MAKEINTRESOURCE(IDD_ABOUTBOX), hWnd, About);
                break;
            case IDM_EXIT:
                DestroyWindow(hWnd);
                break;
            default:
                return DefWindowProc(hWnd, message, wParam, lParam);
            }
        }
        break;
    case WM_PAINT:
        {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hWnd, &ps);
            // TODO: 在此处添加使用 hdc 的任何绘图代码...
            EndPaint(hWnd, &ps);
        }
        break;
    case WM_DESTROY:
        PostQuitMessage(0);
        break;
    default:
        return DefWindowProc(hWnd, message, wParam, lParam);
    }
    return 0;
}

// “关于”框的消息处理程序。
INT_PTR CALLBACK About(HWND hDlg, UINT message, WPARAM wParam, LPARAM lParam)
{
    UNREFERENCED_PARAMETER(lParam);
    switch (message)
    {
    case WM_INITDIALOG:
        return (INT_PTR)TRUE;

    case WM_COMMAND:
        if (LOWORD(wParam) == IDOK || LOWORD(wParam) == IDCANCEL)
        {
            EndDialog(hDlg, LOWORD(wParam));
            return (INT_PTR)TRUE;
        }
        break;
    }
    return (INT_PTR)FALSE;
}
