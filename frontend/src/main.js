import './polyfills/uint8-base64.js'
import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './index.css'
import ui from '@nuxt/ui/vue-plugin'

const app = createApp(App)

app.use(router)
app.use(ui)
app.mount('#app')
