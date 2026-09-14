# 装在自己的 tap 里：
#   brew tap marstechhan/sub2api-bar https://github.com/MarsTechHAN/sub2api-bar.git
#   brew install sub2api-bar
class Sub2apiBar < Formula
  desc "Menu bar indicator for sub2api account quota on macOS"
  homepage "https://github.com/MarsTechHAN/sub2api-bar"
  license "GPL-3.0-or-later"
  head "https://github.com/MarsTechHAN/sub2api-bar.git", branch: "main"

  # 菜单用到 NSMenuItem.sectionHeader，macOS 14 才有
  depends_on macos: :sonoma

  def install
    system "./build.sh"
    prefix.install "build/Sub2API Quota.app"
    # app 里的可执行文件同时也是命令行入口（--endpoint / --dump / --accounts）
    bin.install_symlink prefix/"Sub2API Quota.app/Contents/MacOS/Sub2APIQuota" => "sub2api-bar"
  end

  def caveats
    <<~EOS
      链进「应用程序」，方便 Spotlight 启动和设置开机自启：
        ln -sfn "#{opt_prefix}/Sub2API Quota.app" /Applications/

      先配置，再启动：
        sub2api-bar --endpoint https://sub2api.example.com --api-key admin-xxxxxxxx
        open "#{opt_prefix}/Sub2API Quota.app"

      配置文件在 ~/.config/sub2api-quota/config.json（权限 600）。
    EOS
  end

  test do
    assert_match "Sub2API Quota", shell_output("#{bin}/sub2api-bar --help")
  end
end
