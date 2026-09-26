window.__ModuleLoader__.load({
	id: '@witseek/dsh-client-witseek-desktop',
	factory: (require) => {
		const module = { exports: {} }
		const exports = module.exports
		const react = require('react')

		function WorkspaceSync(props) {
			const cwd = props.useSessions(state => state.byId[props.sessionId]?.cwd)
			react.useEffect(() => {
				const bridge = globalThis.witseekDesktop
				if (typeof bridge?.setWorkspace !== 'function') return
				void bridge.setWorkspace(typeof cwd === 'string' ? cwd : null).catch(error => {
					console.warn('[Witseek] Could not sync the active workspace:', error)
				})
			}, [cwd])
			return null
		}

		const inject = ['slots', 'workspaces']
		function apply(ctx) {
			const workspaces = ctx.get('workspaces')
			const createWorkspace = workspaces.create.bind(workspaces)
			workspaces.create = async (input) => {
				const bridge = globalThis.witseekDesktop
				if (typeof bridge?.validateWorkspace === 'function') {
					await bridge.validateWorkspace(input.path)
				}
				return createWorkspace(input)
			}

			ctx.effect(() => ctx.slots.inject('conversation.session.header.actions', () =>
				ctx.slots.register({
					name: 'conversation.session.header.actions',
					id: 'witseek-workspace-sync',
					order: 1000
				}, WorkspaceSync)), 'witseek-desktop.workspace-sync')
		}

		exports.apply = apply
		exports.inject = inject
		return module.exports
	}
})
