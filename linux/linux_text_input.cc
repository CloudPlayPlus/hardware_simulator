#include "linux_text_input.h"

#include <glib.h>
#ifdef CPP_HAVE_IBUS
#include <ibus.h>
#include <unistd.h>
#include <utility>
#include <vector>
#endif

namespace linux_text_input {
bool valid_text(const std::string& text) {
  if (text.size() > 4096 ||
      !g_utf8_validate(text.data(), text.size(), nullptr)) return false;
  for (const unsigned char ch : text) {
    if (ch < 0x20 || ch == 0x7f) return false;
  }
  return true;
}

#ifdef CPP_HAVE_IBUS
namespace {
using Reply = std::function<void(GVariant*)>;

class Backend {
 public:
  void available(Completion done) {
    if (bus_ && !initializing_) {
      done(ready_ && ibus_bus_is_connected(bus_));
      return;
    }
    waiters_.push_back(std::move(done));
    if (initializing_) return;
    initializing_ = true;
    ibus_init();
    bus_ = ibus_bus_new();
    if (!ibus_bus_is_connected(bus_)) { initialized(false); return; }
    name_ = "cloudplayplus-" + std::to_string(getpid());
    factory_ = ibus_factory_new(ibus_bus_get_connection(bus_));
    g_signal_connect(factory_, "create-engine", G_CALLBACK(create_engine), this);
    auto* component = ibus_component_new(
        name_.c_str(), "CloudPlayPlus committed text", "1", "Proprietary",
        "CloudPlayPlus", "https://cloudplayplus.com", "", "");
    auto* desc = ibus_engine_desc_new(name_.c_str(), "CloudPlayPlus",
        "Remote committed text", "", "Proprietary", "CloudPlayPlus", "", "default");
    ibus_component_add_engine(component, desc);
    call("RegisterComponent", g_variant_new("(v)",
        ibus_serializable_serialize(IBUS_SERIALIZABLE(component))),
        [this](GVariant* reply) { initialized(reply != nullptr); });
    g_object_unref(component);
  }

  void prepare(Prepared done) {
    if (!ready_ || busy_ || !ibus_bus_is_connected(bus_)) { done(0); return; }
    busy_ = true;
    // 不读取目标应用内容，只保存恢复所需 engine 和当前 context 身份。
    call("CurrentInputContext", nullptr, [this, done](GVariant* reply) {
      const char* path = nullptr;
      if (reply) g_variant_get(reply, "(&o)", &path);
      // IBus 1.5.x 在任何客户端之前创建保留 fake context（id=1）。
      // 它也会发出 focus-in，但 CommitText 没有接收方；必须明确失败。
      // 依据：ibus/bus/ibusimpl.c 初始化、bus/inputcontext.c 路径分配。
      if (!path || std::string(path) == "/org/freedesktop/IBus/InputContext_1") {
        busy_ = false; done(0); return;
      }
      context_ = path;
      get_engine([this, done](std::string name) {
        if (name.empty() || name == name_) { busy_ = false; done(0); return; }
        previous_ = name;
        call("SetGlobalEngine", g_variant_new("(s)", name_.c_str()),
             [this, done](GVariant* selected) {
          if (!selected) { restore([done](bool) { done(0); }); return; }
          call("CurrentInputContext", nullptr, [this, done](GVariant* reply) {
            const char* path = nullptr;
            if (reply) g_variant_get(reply, "(&o)", &path);
            if (!path || context_ != path || !engine_ || !focused_) {
              restore([done](bool) { done(0); });
              return;
            }
            token_ = ++next_token_;
            prepared_focus_ = focus_revision_;
            // Dart 丢失连接时仍恢复原输入法；不无限占有临时 engine。
            expiry_ = g_timeout_add(1500, [](gpointer data) -> gboolean {
              auto* self = static_cast<Backend*>(data);
              self->expiry_ = 0;
              self->token_ = 0;
              self->restore([](bool) {});
              return G_SOURCE_REMOVE;
            }, this);
            done(token_);
          });
        });
      });
    });
  }

  void finish(uint64_t token, int backspaces, const std::string& text,
              Completion done) {
    if (!token || token != token_) { done(false); return; }
    token_ = 0;
    if (expiry_) { g_source_remove(expiry_); expiry_ = 0; }
    const bool valid = valid_text(text) && backspaces >= 0 && backspaces <= 4096;
    const bool active = engine_ && focused_ && prepared_focus_ == focus_revision_ &&
        ibus_bus_is_connected(bus_);
    if (valid && active) {
      // 同一 IBus 连接上先转发编辑退格，再提交 Unicode；不与 uinput 混排。
      for (int i = 0; i < backspaces; ++i) {
        ibus_engine_forward_key_event(engine_, IBUS_KEY_BackSpace, 0, 0);
        ibus_engine_forward_key_event(engine_, IBUS_KEY_BackSpace, 0,
                                      IBUS_RELEASE_MASK);
      }
      if (!text.empty()) {
        ibus_engine_commit_text(engine_, ibus_text_new_from_string(text.c_str()));
      }
    }
    restore([done, valid, active](bool restored) {
      done(valid && active && restored);
    });
  }

 private:
  void initialized(bool ok) {
    ready_ = ok;
    initializing_ = false;
    auto waiters = std::move(waiters_);
    for (auto& done : waiters) done(ok);
  }

  static IBusEngine* create_engine(IBusFactory*, const char* name, Backend* self) {
    if (self->name_ != name) return nullptr;
    auto path = "/org/cloudplayplus/IBus/Engine/" + std::to_string(++self->engine_id_);
    auto* engine = ibus_engine_new(name, path.c_str(),
                                   ibus_bus_get_connection(self->bus_));
    self->engine_ = engine;
    self->focused_ = false;
    g_signal_connect(engine, "focus-in", G_CALLBACK(+[](IBusEngine* e, Backend* s) {
      if (s->engine_ != e) return;
      s->focused_ = true;
      ++s->focus_revision_;
      // D-Bus 超时不撤销 daemon 已收到的请求；迟到激活也必须恢复。
      if (!s->busy_ && !s->previous_.empty()) {
        s->busy_ = true;
        s->restore([](bool) {});
      }
    }), self);
    g_signal_connect(engine, "focus-out", G_CALLBACK(+[](IBusEngine* e, Backend* s) {
      if (s->engine_ != e) return;
      s->focused_ = false;
      ++s->focus_revision_;
    }), self);
    g_signal_connect(engine, "disable", G_CALLBACK(+[](IBusEngine* e, Backend* s) {
      if (s->engine_ != e) return;
      s->focused_ = false;
      ++s->focus_revision_;
    }), self);
    g_signal_connect(engine, "destroy", G_CALLBACK(+[](IBusEngine* e, Backend* s) {
      if (s->engine_ == e) { s->engine_ = nullptr; s->focused_ = false; }
    }), self);
    return engine;
  }

  void call(const char* method, GVariant* args, Reply done) {
    auto* callback = new Reply(std::move(done));
    g_dbus_connection_call(ibus_bus_get_connection(bus_), "org.freedesktop.IBus",
        "/org/freedesktop/IBus", "org.freedesktop.IBus", method, args, nullptr,
        G_DBUS_CALL_FLAGS_NONE, 1500, nullptr,
        [](GObject* object, GAsyncResult* result, gpointer data) {
          auto* callback = static_cast<Reply*>(data);
          // 仅传播成功/失败；D-Bus 错误可能包含参数，不转发到产品日志。
          GError* error = nullptr;
          GVariant* reply = g_dbus_connection_call_finish(
              G_DBUS_CONNECTION(object), result, &error);
          (*callback)(reply);
          if (reply) g_variant_unref(reply);
          if (error) g_error_free(error);
          delete callback;
        }, callback);
  }

  void get_engine(std::function<void(std::string)> done) {
    call("GetGlobalEngine", nullptr, [done](GVariant* reply) {
      std::string name;
      if (reply) {
        GVariant* value = nullptr;
        g_variant_get(reply, "(v)", &value);
        auto* object = ibus_serializable_deserialize(value);
        if (object && IBUS_IS_ENGINE_DESC(object)) {
          name = ibus_engine_desc_get_name(IBUS_ENGINE_DESC(object));
        }
        if (object) g_object_unref(object);
        g_variant_unref(value);
      }
      done(name);
    });
  }

  void restore(Completion done) {
    get_engine([this, done](std::string name) {
      if (name != name_) {
        // 用户已切换输入法时不覆盖；连接故障则明确返回失败。
        busy_ = false;
        if (name.empty()) ready_ = false;
        done(!name.empty());
        return;
      }
      call("SetGlobalEngine", g_variant_new("(s)", previous_.c_str()),
           [this, done](GVariant* reply) {
        busy_ = false;
        if (!reply) ready_ = false;
        done(reply != nullptr);
      });
    });
  }

  IBusBus* bus_ = nullptr;
  IBusFactory* factory_ = nullptr;
  IBusEngine* engine_ = nullptr;
  std::string name_, previous_, context_;
  bool ready_ = false, initializing_ = false, busy_ = false, focused_ = false;
  uint64_t next_token_ = 0, token_ = 0, focus_revision_ = 0, prepared_focus_ = 0;
  unsigned engine_id_ = 0, expiry_ = 0;
  std::vector<Completion> waiters_;
};

// IBus 注册对象与进程同寿命；临时激活在每次 finish/expiry 时结束。
Backend& backend() { static auto* value = new Backend(); return *value; }
}  // namespace
void available(Completion done) { backend().available(std::move(done)); }
void prepare(Prepared done) { backend().prepare(std::move(done)); }
void finish(uint64_t token, int backspaces, const std::string& text, Completion done) {
  backend().finish(token, backspaces, text, std::move(done));
}
#else
void available(Completion done) { done(false); }
void prepare(Prepared done) { done(0); }
void finish(uint64_t, int, const std::string&, Completion done) { done(false); }
#endif
}  // namespace linux_text_input
