# 안전에 대해 / Safety

**한국어**

이 앱은 맥의 팬 속도를 직접 바꿉니다. 잘못 쓰면 하드웨어가 뜨거워질 수 있습니다.

- 팬을 최소 속도로 **고정**해 둔 채 무거운 작업(영상 변환, 게임, 컴파일)을 돌리면
  평소보다 온도가 크게 올라갑니다. macOS 자체 보호가 먼저 동작해 성능을 떨어뜨리지만,
  열에 계속 노출되는 것이 부품에 좋을 리는 없습니다.
- 그래서 이 앱에는 **과열 보호**가 기본으로 켜져 있습니다. 설정한 임계 온도를 넘으면
  어떤 모드였든 팬을 최대로 돌립니다. 이 기능을 끄지 마세요.
- 제어 프로그램이 종료되거나 제거될 때는 팬 제어를 항상 macOS 에 돌려줍니다.
  앱이 죽어도 팬이 멈춘 채 남지 않습니다.
- 팬을 최대로 오래 돌리는 것은 안전하지만 수명과 소음에는 영향이 있습니다.

**이 소프트웨어는 어떤 보증도 하지 않습니다. 사용에 따른 책임은 사용자에게 있습니다.**

---

**English**

This app changes your Mac's fan speed directly. Misuse can let hardware run hot.

- **Pinning fans to minimum** while running heavy workloads (video encoding, games,
  compiling) will raise temperatures well above normal. macOS thermal throttling kicks
  in first, but sustained heat is not good for components.
- For that reason **thermal protection is enabled by default**: above the configured
  critical temperature, fans go to maximum regardless of the active mode. Do not disable it.
- When the control helper stops or is removed, fan control is **always returned to macOS**.
  Fans are never left stuck if the app crashes.
- Running fans at maximum is safe but affects noise and bearing lifetime.

**This software comes with NO WARRANTY. Use at your own risk.**
