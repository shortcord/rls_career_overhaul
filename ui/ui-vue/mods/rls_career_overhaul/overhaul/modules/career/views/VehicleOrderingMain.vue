<!-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
     Copyright (C) RLS Modding
     SPDX-License-Identifier: AGPL-3.0-only -->

<!-- Factory vehicle order screen, sharing the vehicle-marketplace presentation: the same search /
     Filters / Sort toolbar, count line, pager and photo-first cards. The catalog is the game's own
     .pc configurations, grouped one card per vehicle; a configuration menu on each card picks the
     trim (default config first), and choosing a card opens the shipping choice and total inline.
     Configurations added by the career mod itself are not part of this catalog. -->
<template>
  <ComputerWrapper title="Order Vehicle" back @back="goBack">
    <div class="rls-house vehicle-order" v-bng-blur>
      <!-- Search, Filters, Sort -->
      <div class="header-section">
        <div class="search-filter-bar">
          <label class="search shop-search" data-focus-field>
            <BngIcon :type="icons.search" class="search-icon" />
            <input
              v-model="query"
              placeholder="Search for a vehicle"
              class="search-input"
              type="text"
              v-bng-text-input
              @keydown.stop @keyup.stop @keypress.stop @input="resetPage" />
            <button v-if="query" type="button" class="search-clear" title="Clear search"
              @mousedown.prevent @click="clearSearch">
              <BngIcon :type="icons.xmark" />
            </button>
          </label>

          <div class="filter-wrap" ref="filterRoot">
            <HouseButton class="filter-btn" :class="{ active: filtersOpen }" :icon="icons.filter"
              @click="toggleFilters">
              Filters
              <span v-if="activeFilterCount" class="pill count-pill">{{ activeFilterCount }}</span>
            </HouseButton>

            <Teleport to="body">
              <div v-show="filtersOpen" ref="filterPanel" class="rls-house filter-panel"
                v-bng-scoped-nav="panelScope" v-bng-on-ui-nav:back,menu="closeFilters" @click.stop>
                <div v-if="brands.length" class="filter-group">
                  <span class="caption">Make</span>
                  <div class="filter-chips">
                    <button v-for="brand in brands" :key="brand" type="button" class="filter-chip"
                      :class="{ set: selectedBrands.includes(brand) }" bng-nav-item
                      @click="toggleBrand(brand)">{{ brand }}</button>
                  </div>
                </div>
                <div v-if="configTypes.length" class="filter-group">
                  <span class="caption">Type</span>
                  <div class="filter-chips">
                    <button v-for="type in configTypes" :key="type" type="button" class="filter-chip"
                      :class="{ set: selectedTypes.includes(type) }" bng-nav-item
                      @click="toggleType(type)">{{ type }}</button>
                  </div>
                </div>
                <div class="filter-group">
                  <span class="caption">Configuration</span>
                  <div class="filter-chips">
                    <button type="button" class="filter-chip" :class="{ set: defaultsOnly }" bng-nav-item
                      @click="toggleDefaultsOnly">Default configs only</button>
                  </div>
                </div>
                <div class="filter-foot">
                  <HouseButton variant="quiet" compact @click="clearFilters">Clear all</HouseButton>
                </div>
              </div>
            </Teleport>
          </div>

          <HouseMenu class="sort-menu" compact v-model="sortKey" :items="sortItems" />
        </div>

        <div v-if="activeChips.length" class="active-chips">
          <button v-for="chip in activeChips" :key="chip.key" type="button" class="active-chip" bng-nav-item
            :title="`Remove ${chip.label}`" @click="chip.remove()">
            <span class="chip-key">{{ chip.label }}</span>
            <span class="chip-value">{{ chip.value }}</span>
            <BngIcon class="chip-x" :type="icons.xmark" />
          </button>
          <HouseButton variant="quiet" compact class="chips-clear" @click="clearAll">Clear all</HouseButton>
        </div>
      </div>

      <!-- Listings -->
      <div class="main-content scroll" v-bng-ui-nav-scroll.force>
        <div class="branch">
          <div v-if="error" class="notice error-notice">
            <BngIcon class="notice-icon" :type="icons.info" />
            <span>{{ error }}</span>
          </div>

          <div v-if="!loading && !data.canOrder" class="notice">
            <BngIcon class="notice-icon" :type="icons.info" />
            <span>Vehicles can only be ordered at a garage you own. This computer is attached to a rented or listed property.</span>
          </div>

          <!-- Incoming orders -->
          <section v-if="pendingOrders.length" class="orders-section">
            <div class="content-heading">
              <h3 class="content-title">Incoming orders</h3>
              <span class="vehicle-count">{{ pendingOrders.length }} pending</span>
            </div>
            <div class="order-list">
              <div v-for="order in pendingOrders" :key="order.id" class="order-row" :data-order-key="order.id">
                <div class="order-main">
                  <strong class="order-name">{{ order.label }}</strong>
                  <span class="hint">{{ order.shippingLabel }} · arrives in {{ formatDuration(order.remaining) }}</span>
                </div>
                <div class="order-side">
                  <span class="money"><BngUnit :money="order.total" /></span>
                  <HouseButton variant="quiet" compact :disabled="busy" @click="cancel(order)">Cancel</HouseButton>
                </div>
              </div>
            </div>
          </section>

          <!-- Count line + page size -->
          <div class="content-header">
            <div class="content-heading">
              <h3 class="content-title">Vehicle Catalog</h3>
              <span class="vehicle-count">{{ filteredVehicles.length }} vehicle{{ filteredVehicles.length !== 1 ? "s" : "" }} found</span>
            </div>
            <HouseMenu class="per-page" compact v-model="itemsPerPage" :items="pageSizeItems" />
          </div>
          <p class="hint taxes">* Prices use the market's catalog valuation; shipping is added at checkout</p>

          <div v-if="loading" class="empty">
            <BngIcon class="empty-icon" :type="icons.car" />
            <h3>Loading vehicle catalog</h3>
            <p>Reading the game's vehicle configurations.</p>
          </div>

          <div v-else-if="!filteredVehicles.length" class="empty">
            <BngIcon class="empty-icon" :type="icons.search" />
            <h3>No vehicles found</h3>
            <p>No vehicles match your search or filters.</p>
          </div>

          <template v-else>
            <div class="vehicle-list-anchor">
              <div v-if="totalPages > 1" class="pager">
                <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ filteredVehicles.length }}</span>
                <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="page <= 1" @click="page = Math.max(1, page - 1)">Prev</HouseButton>
                <span class="pager-page">Page {{ page }} / {{ totalPages }}</span>
                <HouseButton variant="quiet" compact :disabled="page >= totalPages" @click="page = Math.min(totalPages, page + 1)">
                  Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" />
                </HouseButton>
              </div>

              <div class="vehicle-listings">
                <article v-for="group in pageVehicles" :key="group.model" class="vehicle-card"
                  :class="{ selected: isSelected(group) }" :data-vehicle-key="group.model">
                  <div class="vc-row" v-bng-scoped-nav="{ type: 'container', preventNavigationEscape: ['right'] }">
                    <button type="button" class="vc-open" bng-nav-item v-bng-on-ui-nav:ok.asMouse.focusRequired
                      :aria-label="`${group.label} order`" @click="toggleSelection(group)">
                      <span class="sr-only">{{ group.label }} order</span>
                    </button>

                    <div class="vc-photo">
                      <img v-if="cardPreview(group) && !brokenImages.has(cardPreview(group))"
                        :src="cardPreview(group)" alt="" @error="markBroken(cardPreview(group))" />
                      <BngIcon v-else class="photo-fallback" :type="icons.car" />
                    </div>

                    <div class="vc-body">
                      <div class="vc-head">
                        <div class="vc-title">
                          <h3 class="vc-name">{{ group.label }}</h3>
                          <div class="vc-meta">
                            <span class="meta"><BngIcon class="meta-icon" :type="icons.carDealer" />Factory order</span>
                            <span v-if="group.activeConfig?.year" class="meta">
                              <BngIcon class="meta-icon" :type="icons.mapPoint" />{{ group.activeConfig.year }}
                            </span>
                            <span v-if="group.activeConfig?.configType" class="pill">
                              <BngIcon class="pill-icon" :type="icons.car" />{{ group.activeConfig.configType }}
                            </span>
                            <span v-if="group.activeConfig?.isDefault" class="pill default-pill">Default</span>
                          </div>
                        </div>
                        <div class="vc-side">
                          <div class="vc-price"
                            :class="{ bad: hasPrice(group.activeConfig) && !canAffordVehicle(group), unavailable: !hasPrice(group.activeConfig) }">
                            <BngUnit v-if="hasPrice(group.activeConfig)" :money="group.activeConfig.price" />
                            <span v-else>Price unavailable</span>
                          </div>
                          <span v-if="hasPrice(group.activeConfig) && !canAffordVehicle(group)" class="vc-flag">Insufficient funds</span>
                        </div>
                      </div>

                      <dl class="vc-keyspecs">
                        <div class="spec"><dt>Power</dt><dd>{{ powerText(group.activeConfig) }}</dd></div>
                        <div class="spec"><dt>Drivetrain</dt><dd>{{ group.activeConfig?.drivetrain || "—" }}</dd></div>
                        <div class="spec"><dt>Gearbox</dt><dd>{{ group.activeConfig?.transmission || "—" }}</dd></div>
                        <div class="spec"><dt>Odometer</dt><dd>New</dd></div>
                      </dl>

                      <!-- Configurations of this vehicle (default first) -->
                      <div class="config-row">
                        <span class="config-caption">Configuration</span>
                        <HouseMenu v-if="group.configs.length > 1" class="config-menu" compact
                          v-model="configChoice[group.model]" :items="configItems(group)"
                          @change="onConfigChange(group)" />
                        <span v-else class="config-single">{{ group.activeConfig?.configLabel || "Default" }}</span>
                        <span class="config-count">{{ group.configs.length }} available</span>
                      </div>

                      <div class="vc-actions">
                        <HouseButton compact class="details-btn" bng-no-nav="true" :disabled="!data.canOrder"
                          @click="toggleSelection(group)">
                          {{ isSelected(group) ? "Close" : "Order" }}<BngIcon class="details-chev" :type="icons.arrowSmallRight" />
                        </HouseButton>
                      </div>

                      <!-- Shipping choice for the chosen configuration -->
                      <div v-if="isSelected(group)" class="order-form" @click.stop>
                        <div v-for="option in shippingList" :key="option.id" class="ship-option"
                          :class="{ active: shipping === option.id }" tabindex="0" bng-nav-item
                          v-bng-on-ui-nav:ok.asMouse.focusRequired @click="shipTo(option.id)">
                          <div class="ship-main">
                            <span class="ship-title">{{ option.label }}</span>
                            <span class="hint">{{ option.description }}</span>
                          </div>
                          <div class="ship-cost"><BngUnit :money="option.cost" /></div>
                        </div>

                        <div class="order-total">
                          <span class="hint order-breakdown">
                            <template v-if="hasPrice(group.activeConfig)">
                              {{ group.activeConfig.configLabel }} <BngUnit :money="group.activeConfig.price" />
                              + shipping <BngUnit :money="selectedShipping.cost" />
                            </template>
                            <template v-else>This configuration has no catalog price.</template>
                          </span>
                          <strong v-if="hasPrice(group.activeConfig)" class="order-total-value">Total <BngUnit :money="orderTotal" /></strong>
                        </div>

                        <div class="order-actions">
                          <HouseButton variant="primary" :disabled="busy || !data.canOrder || !hasPrice(group.activeConfig) || !canAffordOrder" @click="place(group)">
                            Place order
                          </HouseButton>
                          <HouseButton variant="quiet" :disabled="busy" @click="clearSelection">Cancel</HouseButton>
                        </div>
                        <p v-if="!hasPrice(group.activeConfig)" class="hint warning">This configuration has no catalog price, so it cannot be ordered.</p>
                        <p v-else-if="!canAffordOrder" class="hint warning">You do not have enough money for this order.</p>
                      </div>
                    </div>
                  </div>
                </article>
              </div>

              <div v-if="totalPages > 1" class="pager">
                <span class="pager-range">{{ pageStart }}–{{ pageEnd }} of {{ filteredVehicles.length }}</span>
                <HouseButton variant="quiet" compact :icon="icons.arrowSmallLeft" :disabled="page <= 1" @click="page = Math.max(1, page - 1)">Prev</HouseButton>
                <span class="pager-page">Page {{ page }} / {{ totalPages }}</span>
                <HouseButton variant="quiet" compact :disabled="page >= totalPages" @click="page = Math.min(totalPages, page + 1)">
                  Next <BngIcon class="pager-chev" :type="icons.arrowSmallRight" />
                </HouseButton>
              </div>
            </div>
          </template>
        </div>
      </div>
    </div>
  </ComputerWrapper>
</template>

<script setup>
import { ref, reactive, computed, watch, nextTick, onMounted, onUnmounted, Teleport } from "vue"
import { lua, useBridge } from "@/bridge"
import { useRoute } from "vue-router"
import { useEvents } from "@/services/events"
import { BngIcon, BngUnit, icons } from "@/common/components/base"
import { vBngBlur, vBngOnUiNav, vBngScopedNav, vBngTextInput, vBngUiNavScroll } from "@/common/directives"
import { HouseButton, HouseMenu } from "../components/house/index.js"
import ComputerWrapper from "./ComputerWrapper.vue"
import "../utils/installLuaBridgeFallbacks.js"
import { useScreenEntry } from "../composables/useScreenEntryFocus"
import { reportUiFailure } from "../utils/safeLua"

const route = useRoute()
const events = useEvents()
const { units } = useBridge()
const focusScreenEntry = useScreenEntry()
const computerId = route.params.computerId || route.query.computerId

const data = ref({ catalog: [], orders: [], shipping: {}, money: 0, canOrder: false })
const loading = ref(true)
const query = ref("")
const page = ref(1)
const itemsPerPage = ref(25)
const sortKey = ref("price_asc")
const selectedBrands = ref([])
const selectedTypes = ref([])
const defaultsOnly = ref(false)
const filtersOpen = ref(false)
const filterRoot = ref(null)
const filterPanel = ref(null)
const configChoice = reactive({})
const selected = ref(null)
const shipping = ref("standard")
const busy = ref(false)
const error = ref(null)

const sortItems = [
  { value: "price_asc", label: "Price, low to high" },
  { value: "price_desc", label: "Price, high to low" },
  { value: "name_asc", label: "Name, A to Z" },
  { value: "year_desc", label: "Year, newest first" },
  { value: "power_desc", label: "Power, high to low" },
]
const pageSizeItems = [
  { value: 10, label: "10 per page" },
  { value: 25, label: "25 per page" },
  { value: 50, label: "50 per page" },
  { value: 100, label: "100 per page" },
]

// ---- catalog -------------------------------------------------------------------------------------
const load = async () => {
  try {
    const result = await lua.overhaul_career_market_vehicleOrdering.getUiData(computerId || undefined)
    data.value = result || {}
    if (selected.value) {
      selected.value = (data.value.catalog || []).find(
        entry => entry.model === selected.value.model && entry.config === selected.value.config,
      ) || null
    }
  } catch (err) {
    reportUiFailure(err, "vehicle ordering catalog")
    error.value = "Could not load the vehicle catalog."
  } finally {
    loading.value = false
  }
}

const hasPrice = config => Number.isFinite(Number(config?.price)) && Number(config.price) > 0
const priceRank = config => (hasPrice(config) ? Number(config.price) : Number.POSITIVE_INFINITY)

const pickDefault = configs =>
  configs.find(config => config.isDefault && hasPrice(config)) ||
  configs.find(config => config.isDefault) ||
  configs.find(hasPrice) ||
  configs[0]

// One group per vehicle model; configurations keep the game's own order with the default first.
const allVehicles = computed(() => {
  const map = new Map()
  for (const config of data.value.catalog || []) {
    let group = map.get(config.model)
    if (!group) {
      group = {
        model: config.model,
        brand: config.brand,
        modelName: config.modelName || config.name || config.model,
        modelPreview: config.modelPreview,
        configs: [],
      }
      group.label = [config.brand, group.modelName].filter(Boolean).join(" ") || config.model
      map.set(config.model, group)
    }
    group.configs.push(config)
  }
  const groups = [...map.values()]
  for (const group of groups) {
    group.configs.sort((a, b) =>
      (b.isDefault ? 1 : 0) - (a.isDefault ? 1 : 0) ||
      String(a.configLabel || a.name || a.config).localeCompare(String(b.configLabel || b.name || b.config)))
    group.defaultConfig = pickDefault(group.configs)
    group.year = Math.max(0, ...group.configs.map(config => Number(config.year) || 0))
    group.power = Math.max(0, ...group.configs.map(config => Number(config.power) || 0))
  }
  groups.sort((a, b) => a.label.localeCompare(b.label))
  return groups
})

const brands = computed(() => {
  const set = new Set()
  for (const group of allVehicles.value) if (group.brand) set.add(group.brand)
  return [...set].sort((a, b) => a.localeCompare(b))
})
const configTypes = computed(() => {
  const set = new Set()
  for (const config of data.value.catalog || []) if (config.configType) set.add(config.configType)
  return [...set].sort((a, b) => a.localeCompare(b))
})

// ---- filter / sort / page ------------------------------------------------------------------------
const filteredVehicles = computed(() => {
  const needle = query.value.trim().toLowerCase()
  const types = selectedTypes.value
  const out = []
  for (const group of allVehicles.value) {
    if (selectedBrands.value.length && !selectedBrands.value.includes(group.brand)) continue
    let configs = group.configs
    if (defaultsOnly.value) configs = configs.filter(config => config.isDefault)
    if (types.length) configs = configs.filter(config => types.includes(config.configType))
    const groupMatches = !needle ||
      `${group.label} ${group.brand || ""} ${group.modelName || ""} ${group.model}`.toLowerCase().includes(needle)
    if (!groupMatches) {
      configs = configs.filter(config =>
        `${config.name || ""} ${config.configLabel || ""}`.toLowerCase().includes(needle))
    }
    if (!configs.length) continue
    out.push({ ...group, configs, defaultConfig: pickDefault(configs) })
  }
  const direction = sortKey.value.endsWith("_desc") ? -1 : 1
  out.sort((a, b) => {
    switch (sortKey.value) {
      case "price_asc":
      case "price_desc":
        return (priceRank(a.defaultConfig) - priceRank(b.defaultConfig)) * direction
      case "year_desc":
        return ((a.year || 0) - (b.year || 0)) * direction
      case "power_desc":
        return ((a.power || 0) - (b.power || 0)) * direction
      default:
        return String(a.label || "").localeCompare(String(b.label || "")) * direction
    }
  })
  return out
})

const totalPages = computed(() => Math.max(1, Math.ceil(filteredVehicles.value.length / itemsPerPage.value)))
const pageStart = computed(() =>
  filteredVehicles.value.length ? (page.value - 1) * itemsPerPage.value + 1 : 0)
const pageEnd = computed(() => Math.min(page.value * itemsPerPage.value, filteredVehicles.value.length))

const chosenConfig = group => {
  const key = configChoice[group.model]
  return group.configs.find(config => config.config === key) || group.defaultConfig
}
const configItems = group => group.configs.map(config => ({
  value: config.config,
  label: config.configLabel || config.name || config.config,
}))
const pageVehicles = computed(() => filteredVehicles.value
  .slice((page.value - 1) * itemsPerPage.value, page.value * itemsPerPage.value)
  .map(group => ({ ...group, activeConfig: chosenConfig(group) })))

// Keep a valid configuration selected when the catalog or the filtered set changes.
watch([allVehicles, filteredVehicles], ([, groups]) => {
  for (const group of groups) {
    if (!group.configs.some(config => config.config === configChoice[group.model])) {
      configChoice[group.model] = group.defaultConfig?.config
    }
  }
}, { immediate: true })

const resetPage = () => { page.value = 1 }
const clearSearch = () => { query.value = ""; resetPage() }
const toggleBrand = brand => {
  const set = new Set(selectedBrands.value)
  set.has(brand) ? set.delete(brand) : set.add(brand)
  selectedBrands.value = [...set]
  resetPage()
}
const toggleType = type => {
  const set = new Set(selectedTypes.value)
  set.has(type) ? set.delete(type) : set.add(type)
  selectedTypes.value = [...set]
  resetPage()
}
const toggleDefaultsOnly = () => { defaultsOnly.value = !defaultsOnly.value; resetPage() }
const clearFilters = () => {
  selectedBrands.value = []
  selectedTypes.value = []
  defaultsOnly.value = false
  resetPage()
}
const clearAll = () => { clearSearch(); clearFilters() }

const activeFilterCount = computed(() =>
  selectedBrands.value.length + selectedTypes.value.length + (defaultsOnly.value ? 1 : 0))
const activeChips = computed(() => {
  const chips = []
  if (query.value.trim()) {
    chips.push({ key: "search", label: "Search", value: query.value.trim(), remove: clearSearch })
  }
  for (const brand of selectedBrands.value) {
    chips.push({ key: `brand:${brand}`, label: "Make", value: brand, remove: () => toggleBrand(brand) })
  }
  for (const type of selectedTypes.value) {
    chips.push({ key: `type:${type}`, label: "Type", value: type, remove: () => toggleType(type) })
  }
  if (defaultsOnly.value) {
    chips.push({ key: "defaults", label: "Configuration", value: "Default only", remove: toggleDefaultsOnly })
  }
  return chips
})

watch([query, selectedBrands, selectedTypes, defaultsOnly, sortKey, itemsPerPage], () => {
  if (page.value > totalPages.value) page.value = totalPages.value
})

// ---- cards ---------------------------------------------------------------------------------------
const money = computed(() => Number(data.value.money) || 0)
const powerText = config => (config?.power ? units.buildString("power", config.power, 0) : "—")
const cardPreview = group => group.activeConfig?.preview || group.modelPreview || null
const canAffordVehicle = group => hasPrice(group.activeConfig) && Number(group.activeConfig.price) <= money.value

const brokenImages = ref(new Set())
const markBroken = url => { brokenImages.value = new Set(brokenImages.value).add(url) }

const isSelected = group =>
  !!selected.value && !!group.activeConfig &&
  selected.value.model === group.activeConfig.model && selected.value.config === group.activeConfig.config
const toggleSelection = group => { isSelected(group) ? clearSelection() : select(group) }
const select = group => {
  if (!data.value.canOrder) return
  const config = chosenConfig(group)
  if (!config) return
  selected.value = config
  shipping.value = "standard"
  error.value = null
}
const clearSelection = () => { selected.value = null }
const shipTo = id => { shipping.value = id }
const onConfigChange = group => {
  if (selected.value?.model !== group.model) return
  const config = chosenConfig(group)
  if (config) selected.value = config
}

const shippingList = computed(() =>
  Object.values(data.value.shipping || {}).sort((a, b) => (a.cost || 0) - (b.cost || 0)))
const selectedShipping = computed(() => (data.value.shipping || {})[shipping.value] || shippingList.value[0] || { cost: 0 })
const orderTotal = computed(() => (Number(selected.value?.price) || 0) + (selectedShipping.value?.cost || 0))
const canAffordOrder = computed(() => hasPrice(selected.value) && orderTotal.value <= money.value)

const pendingOrders = computed(() => (data.value.orders || []).filter(order => order.status === "pending"))

const formatDuration = seconds => {
  const total = Math.max(0, Math.ceil(Number(seconds) || 0))
  const minutes = Math.floor(total / 60)
  const rest = total % 60
  return minutes > 0 ? `${minutes}m ${rest}s` : `${rest}s`
}

const place = async group => {
  const config = chosenConfig(group)
  if (!config || !hasPrice(config) || busy.value) return
  busy.value = true
  error.value = null
  try {
    const result = await lua.overhaul_career_market_vehicleOrdering.requestOrder(
      config.model, config.config, shipping.value, computerId || undefined)
    if (!result?.ok) {
      error.value = result?.error || "The order could not be placed."
      return
    }
    selected.value = null
    await load()
  } catch (err) {
    reportUiFailure(err, "vehicle order placement")
    error.value = "The order could not be placed."
  } finally {
    busy.value = false
  }
}

const cancel = async order => {
  if (busy.value || !order?.id) return
  busy.value = true
  error.value = null
  try {
    const result = await lua.overhaul_career_market_vehicleOrdering.requestCancelOrder(order.id)
    if (!result?.ok) error.value = result?.error || "The order could not be cancelled."
    await load()
  } catch (err) {
    reportUiFailure(err, "vehicle order cancellation")
    error.value = "The order could not be cancelled."
  } finally {
    busy.value = false
  }
}

const goBack = () => lua.extensions.ui_router.back()
const onUpdated = () => { if (!busy.value) load() }

// The panel is teleported to the body so the screen card's overflow cannot clip it; position it
// under the toolbar, as wide as the toolbar and kept inside the window.
const panelScope = {
  type: "container",
  preventNavigationEscape: ["top", "bottom", "left", "right"],
  canBubbleEvent: event => !["back", "menu", "ok"].includes(event?.detail?.name),
}

const positionFilterPanel = () => {
  if (!filterRoot.value || !filterPanel.value) return
  const trigger = filterRoot.value.querySelector(".filter-btn")
  if (!trigger) return
  const rect = trigger.getBoundingClientRect()
  const bar = filterRoot.value.closest(".search-filter-bar") || filterRoot.value
  const barRect = bar.getBoundingClientRect()
  const el = filterPanel.value
  const margin = 12
  el.style.position = "fixed"
  el.style.zIndex = "12000"
  el.style.top = `${rect.bottom + 6}px`
  el.style.width = `${Math.min(Math.max(barRect.width, 320), window.innerWidth - 2 * margin)}px`
  const width = el.offsetWidth || barRect.width
  el.style.left = `${Math.max(margin, Math.min(barRect.left, window.innerWidth - width - margin))}px`
  el.style.maxHeight = `${Math.max(160, window.innerHeight - rect.bottom - margin * 2)}px`
  el.style.overflowY = "auto"
}

const closeFilters = () => {
  filtersOpen.value = false
  nextTick(() => filterRoot.value?.querySelector(".filter-btn")?.focus())
  return false
}
const toggleFilters = () => { filtersOpen.value = !filtersOpen.value }

watch(filtersOpen, async open => {
  if (open) {
    await nextTick()
    positionFilterPanel()
    window.addEventListener("resize", positionFilterPanel)
    window.addEventListener("scroll", positionFilterPanel, true)
  } else {
    window.removeEventListener("resize", positionFilterPanel)
    window.removeEventListener("scroll", positionFilterPanel, true)
  }
})

const onDocDown = event => {
  if (!filtersOpen.value) return
  if (filterRoot.value?.contains(event.target) || filterPanel.value?.contains(event.target)) return
  filtersOpen.value = false
}

// Local countdown while an order is in transit; the server owns the actual delivery time.
let clock = null
let nextDueRefresh = 0
const startClock = () => {
  clock = setInterval(() => {
    let due = false
    const nowMs = Date.now()
    for (const order of data.value.orders || []) {
      if (order.status !== "pending") continue
      order.remaining = Math.max(0, (order.remaining || 0) - 1)
      if (order.remaining === 0 && nowMs > nextDueRefresh) due = true
    }
    if (due) {
      nextDueRefresh = nowMs + 5000
      load()
    }
  }, 1000)
}

onMounted(() => {
  events.on("vehicleOrderingUpdated", onUpdated)
  document.addEventListener("mousedown", onDocDown, true)
  load().then(() => focusScreenEntry())
  startClock()
})

onUnmounted(() => {
  events.off("vehicleOrderingUpdated", onUpdated)
  document.removeEventListener("mousedown", onDocDown, true)
  window.removeEventListener("resize", positionFilterPanel)
  window.removeEventListener("scroll", positionFilterPanel, true)
  if (clock) clearInterval(clock)
  clock = null
})
</script>

<style scoped lang="scss">
@use "@/styles/rls_career_overhaul/modules/career/styles/rlsHouse.scss" as *;

/* Screen card: same frame and typography as the vehicle marketplace list. */
.vehicle-order.rls-house {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  flex: 0 1 auto;
  min-height: 0;
  max-height: 100%;
  width: min(64em, 100%);
  display: flex;
  flex-direction: column;
  margin: 0;
  overflow: hidden;
  color: #fff;
  background: rgba(21, 21, 23, 0.93);
  border-radius: var(--radius-control);
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.06), 0 14px 40px rgba(0, 0, 0, 0.45);
}

/* ---- search, filters, sort */
.header-section {
  flex: 0 0 auto;
  position: relative;
  z-index: 5;
  padding: 0.9em 1.1em 0.75em;
  border-bottom: 1px solid var(--line);
}
.search-filter-bar {
  display: flex;
  align-items: stretch;
  flex-wrap: wrap;
  gap: var(--space-2);
}
.shop-search {
  flex: 1 1 18em;
  width: auto;
  min-width: 14em;
  min-height: 2.3em;
  cursor: text;
  .search-icon {
    flex: 0 0 auto;
    font-size: 1.1em;
    color: var(--faint);
  }
  .search-input {
    font-size: 1em;
  }
  .search-clear {
    flex: 0 0 auto;
    font-size: 0.9em;
  }
}
.filter-wrap {
  position: relative;
  flex: 0 0 auto;
}
.filter-btn.active,
.filter-btn:hover {
  background: var(--panel-hover);
}
.filter-btn .count-pill {
  margin-left: 0.1em;
  padding: 0.38em 0.45em 0.12em;
  font-size: 0.78em;
  background: var(--panel-hover);
  color: #fff;
  font-variant-numeric: tabular-nums;
}
.filter-panel {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: grid;
  gap: 0.55em;
  max-width: calc(100vw - 24px);
  padding: 0.8em 0.85em 0.65em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 12px 28px rgba(0, 0, 0, 0.5);
}
.filter-group {
  display: grid;
  gap: 0.35em;
}
.filter-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35em;
}
.filter-chip {
  appearance: none;
  margin: 0;
  padding: 0.45em 0.7em 0.3em;
  border: 0;
  border-radius: var(--radius-pill);
  background: var(--panel);
  color: var(--muted);
  font: inherit;
  font-size: 0.85em;
  font-weight: 700;
  line-height: 1;
  cursor: pointer;
  transition: background-color 0.12s, color 0.12s;
  &:hover {
    background: var(--panel-2);
    color: #fff;
  }
  &.set {
    color: #fff;
    background: var(--panel-hover);
    box-shadow: inset 0 0 0 1px var(--money);
  }
  @include house-focus;
}
.filter-foot {
  display: flex;
  justify-content: flex-end;
}
.sort-menu {
  flex: 0 0 auto;
  font-size: 0.95em;
}

/* active filter chips under the toolbar */
.active-chips {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.4em;
  margin-top: 0.6em;
}
.active-chip {
  position: relative;
  appearance: none;
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  margin: 0;
  padding: 0.5em 0.55em 0.38em 0.75em;
  border: 0;
  border-radius: var(--radius-control);
  background: var(--panel);
  color: #fff;
  font: inherit;
  font-size: 0.85em;
  font-weight: 700;
  line-height: 1;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
  cursor: pointer;
  transition: background-color 0.12s;
  .chip-key {
    color: var(--faint);
  }
  .chip-x {
    margin-left: 0.1em;
    font-size: 0.85em;
    color: var(--faint);
    transform: translateY(-0.05em);
  }
  &:hover {
    background: var(--panel-2);
    .chip-x {
      color: #fff;
    }
  }
  @include house-focus;
}
.chips-clear {
  font-size: 0.85em;
}

/* ---- scrolling content */
.main-content {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  padding: 1em 0.6em 1.2em 1.1em;
}
.branch {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
  padding-right: 0.4em;
}
.taxes {
  margin: -0.35em 0 0;
  font-size: 0.78em;
}
.notice {
  display: flex;
  align-items: center;
  gap: 0.6em;
  padding: 0.7em 0.9em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: var(--muted);
  font-weight: 600;
}
.notice.error-notice {
  color: var(--bad);
}
.notice-icon {
  flex: 0 0 auto;
  font-size: 1.15em;
  color: var(--faint);
}

/* count line + page-size menu */
.content-header {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 1em;
}
.content-heading {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 0.2em 0.75em;
  min-width: 0;
}
.content-title {
  margin: 0;
  font-size: 1.25em;
  font-weight: 800;
  line-height: 1.15;
}
.vehicle-count {
  color: var(--faint);
  font-size: 0.85em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.per-page {
  flex: 0 0 auto;
  font-size: 0.88em;
  :deep(.menu-list) {
    left: auto;
    right: 0;
  }
}

/* ---- pager */
.pager {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: 0.35em 0.5em;
  font-variant-numeric: tabular-nums;
}
.pager-range {
  margin-right: auto;
  color: var(--faint);
  font-size: 0.82em;
  font-weight: 600;
}
.pager-page {
  min-width: 6.5em;
  color: var(--muted);
  font-size: 0.88em;
  font-weight: 700;
  text-align: center;
}
.pager-chev {
  font-size: 1.1em;
  margin-left: 0.15em;
  transform: translateY(0.05em);
}

/* ---- listing cards (same shape as the vehicle marketplace card) */
.vehicle-list-anchor {
  display: flex;
  flex-direction: column;
  gap: 0.85em;
}
.vehicle-listings {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
}
.vehicle-card {
  border-radius: var(--radius-panel);
  background: var(--panel);
  color: #fff;
  transition: background-color 0.12s;
  &:hover,
  &:focus-within,
  &.selected {
    background: var(--panel-2);
  }
}
.vc-row {
  position: relative;
  display: grid;
  grid-template-columns: 17em minmax(0, 1fr);
  gap: 1.1em;
  align-items: stretch;
  padding: 0.6em 0.75em 0.6em 0.6em;
  border-radius: inherit;
  cursor: pointer;
}
.vc-open {
  position: absolute;
  inset: 0;
  z-index: 1;
  border: 0;
  border-radius: inherit;
  background: transparent;
  cursor: pointer;
  @include house-focus(var(--focus-inset));
}
.vc-actions,
.config-row,
.order-form {
  position: relative;
  z-index: 2;
}
.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
}
.vc-photo {
  position: relative;
  display: grid;
  place-items: center;
  align-self: start;
  aspect-ratio: 16 / 9;
  border-radius: var(--radius-thumb);
  overflow: hidden;
  background: var(--photo);
  img {
    display: block;
    width: 100%;
    height: 100%;
    object-fit: contain;
  }
}
.photo-fallback {
  font-size: 3em;
  color: rgba(255, 255, 255, 0.22);
}
.vc-body {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  min-width: 0;
  padding-top: 0.15em;
}
.vc-head {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 0.3em 1em;
  align-items: start;
}
.vc-title {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.vc-name {
  margin: 0;
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.15;
  overflow-wrap: anywhere;
}
.vc-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35em 1.1em;
  min-width: 0;
  margin-top: 0.35em;
}
.meta {
  display: flex;
  align-items: center;
  gap: 0.45em;
  color: var(--faint);
  font-size: 0.86em;
  font-weight: 600;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
.meta-icon {
  flex: 0 0 auto;
  font-size: 1.1em;
  color: var(--faint);
}
.pill .pill-icon {
  font-size: 1.05em;
  color: var(--faint);
  transform: translateY(-0.1em);
}
.pill.default-pill {
  background: rgba(255, 255, 255, 0.14);
  color: #fff;
}
.vc-side {
  display: grid;
  justify-items: end;
  gap: 0.2em;
  text-align: right;
}
.vc-price {
  color: var(--money);
  font-size: 1.3em;
  font-weight: 800;
  line-height: 1.1;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  :deep(.bng-unit),
  :deep(.unit) {
    color: inherit;
  }
  &.bad {
    color: var(--bad);
  }
  &.unavailable {
    color: var(--faint);
    font-size: 1em;
    font-weight: 600;
  }
}
.vc-flag {
  color: var(--bad);
  font-size: 0.78em;
  font-weight: 700;
}
.vc-keyspecs {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0;
  margin: 0;
  padding: 0.5em 0;
  border-radius: var(--radius-tile);
  background: rgba(0, 0, 0, 0.22);
  box-shadow: inset 0 0 0 1px var(--line);
}
.spec {
  display: grid;
  gap: 0.2em;
  min-width: 0;
  padding: 0 0.8em;
  & + .spec {
    box-shadow: -1px 0 0 var(--line);
  }
  dt {
    color: var(--faint);
    font-size: 0.7em;
    font-weight: 700;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }
  dd {
    margin: 0;
    color: rgba(255, 255, 255, 0.86);
    font-size: 0.92em;
    font-weight: 600;
    line-height: 1.2;
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
}

/* configuration picker: one vehicle, several trims */
.config-row {
  display: flex;
  align-items: center;
  gap: 0.6em;
  min-width: 0;
}
.config-caption {
  flex: 0 0 auto;
  color: var(--faint);
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
}
.config-menu {
  flex: 0 1 20em;
  min-width: 10em;
  font-size: 0.9em;
  :deep(.menu-list) {
    left: 0;
    right: auto;
  }
}
.config-single {
  color: rgba(255, 255, 255, 0.86);
  font-size: 0.92em;
  font-weight: 600;
}
.config-count {
  margin-left: auto;
  color: var(--faint);
  font-size: 0.78em;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.vc-actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 0.4em;
  margin-top: auto;
}
.details-btn :deep(.btn-label) {
  display: inline-flex;
  align-items: center;
  gap: 0.25em;
}
.details-chev {
  font-size: 1.1em;
}

/* ---- inline shipping / order panel */
.order-form {
  display: grid;
  gap: 0.55em;
  margin-top: 0.15em;
  padding: 0.6em;
  border-radius: var(--radius-panel);
  background: rgba(0, 0, 0, 0.28);
  box-shadow: inset 0 0 0 1px var(--line);
  animation: order-in 0.16s ease-out;
}
@keyframes order-in {
  from {
    opacity: 0;
    transform: translateY(-0.25em);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
.ship-option {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1em;
  padding: 0.55em 0.7em;
  border-radius: var(--radius-panel);
  background: var(--panel);
  box-shadow: inset 0 0 0 1px transparent;
  cursor: pointer;
  &.active {
    background: var(--panel-2);
    box-shadow: inset 0 0 0 2px var(--money);
  }
  @include house-focus;
}
.ship-main {
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.ship-title {
  font-size: 0.98em;
  font-weight: 700;
}
.ship-cost {
  flex: 0 0 auto;
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.order-total {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.4em 1em;
}
.order-breakdown {
  display: inline-flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 0.2em;
}
.order-total-value {
  color: var(--money);
  font-size: 1.1em;
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.order-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45em;
}
.warning {
  color: var(--warn);
}

/* ---- incoming orders */
.orders-section {
  display: grid;
  gap: 0.5em;
  padding-bottom: 0.35em;
  border-bottom: 1px solid var(--line);
}
.order-list {
  display: grid;
  gap: 0.4em;
}
.order-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1em;
  padding: 0.6em 0.8em;
  border-radius: var(--radius-panel);
  background: var(--panel);
}
.order-main {
  display: grid;
  gap: 0.2em;
  min-width: 0;
}
.order-name {
  font-size: 1em;
  overflow-wrap: anywhere;
}
.order-side {
  display: flex;
  align-items: center;
  gap: 0.8em;
  flex: 0 0 auto;
}
.money {
  color: var(--money);
  font-weight: 800;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

/* ---- empty state */
.empty {
  border-radius: var(--radius-panel);
  background: var(--panel);
  padding: 2.4em 1.2em;
  text-align: center;
  .empty-icon {
    font-size: 2.4em;
    color: var(--faint);
  }
  h3 {
    margin: 0.4em 0 0.2em;
    font-size: 1.1em;
    font-weight: 800;
  }
  p {
    margin: 0;
    color: var(--muted);
    font-size: 0.9em;
  }
}

/* narrow screens: photo above the body */
@media (max-width: 900px) {
  .vc-row {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
