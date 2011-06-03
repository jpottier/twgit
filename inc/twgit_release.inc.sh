#!/bin/bash

assert_git_repository

##
# Affiche l'aide de la commande tag.
#
function usage () {
	echo; help 'Usage:'
	help_detail 'twgit release <action>'
	echo; help 'Available actions are:'
	help_detail '<b>list</b>'
	help_detail '    List remote releases. Add <b>-f</b> to do not make fetch.'; echo
	help_detail '<b>finish <releasename> [<tagname>]</b>'
	help_detail "    Merge specified release branch into '$TWGIT_STABLE', create a new tag and push."
	help_detail '    If no <tagname> is specified then <releasename> will be used.'; echo
	help_detail '<b>remove <releasename></b>'
	help_detail '    Remove both local and remote specified release branch.'; echo
	help_detail '<b>reset <releasename></b>'
	help_detail '    Call remove <releasename> and start <releasename>'; echo
	help_detail '<b>start [<releasename>] [-M|-m]</b>'
	help_detail '    Create both a new local and remote release,'
	help_detail '    or fetch the remote release if <releasename> exists on remote repository.'
	help_detail "    Prefix '$TWGIT_PREFIX_RELEASE' will be added to the specified <releasename>."
	help_detail '    If no <releasename> is specified, a name will be generated from last tag:'
	help_detail '        <b>-M</b> for a new major version'
	help_detail '        <b>-m</b> for a new minor version (default)'; echo
	help_detail '<b>[help]</b>'
	help_detail '    Display this help.'; echo
}

##
# Action déclenchant l'affichage de l'aide.
#
function cmd_help () {
	usage;
}

##
# Liste les releases ainsi que leurs éventuelles features associées.
# Gère l'option '-f' permettant d'éviter le fetch.
#
function cmd_list () {
	process_options "$@"
	process_fetch 'f'

	local releases=$(git branch -r --merged $TWGIT_ORIGIN/$TWGIT_STABLE | grep "$TWGIT_ORIGIN/$TWGIT_PREFIX_RELEASE" | sed 's/^[* ]*//')
	if [ ! -z $releases ]; then
		help "Remote releases merged into '<b>$TWGIT_STABLE</b>':"
		warn "A release must be deleted after merge into '<b>$TWGIT_STABLE</b>'! Following releases would not exists!"
		display_branches 'Release: ' "$releases"
	fi

	local release=$(get_current_release_in_progress)
	help "Remote release NOT merged into '<b>$TWGIT_STABLE</b>':"
	display_branches 'Release: ' "$release" | head -n -1
	if [ ! -z "$release" ]; then
		echo 'Features:'
		local features="$(get_merged_features $release)"
		for f in $features; do echo "    - $f [merged]"; done
		features="$(get_features merged_in_progress $release)"
		for f in $features; do echo "    - $f [merged, then in progress]"; done
	fi
	echo
}

##
# Crée une nouvelle release à partir du dernier tag.
# Si le nom n'est pas spécifié, un nom sera généré automatiquement à partir du dernier tag
# en incrémentant par défaut d'une version mineure. Ce comportement est modifiable via les
# options -M (major) ou -m (minor).
# Rappel : une version c'est major.minor.revision
#
# @param string $1 nom court optionnel de la nouvelle release.
#
function cmd_start () {
	process_options "$@"
	require_parameter '-'
	local release="$RETVAL"
	local release_fullname

	[[ $(get_releases_in_progress | wc -w) > 0 ]] && die "No more one release is authorized at the same time! Try: twgit release list"
	assert_tag_exists
	local last_tag=$(get_last_tag)

	if [ -z $release ]; then
		local type
		if isset_option 'M'; then type='major'
		else type='minor'
		fi
		release=$(get_next_version $type)
		release_fullname="$TWGIT_PREFIX_RELEASE$release"
		echo "Release: $release_fullname"
		echo -n $(question 'Do you want to continue? [Y/N] '); read answer
		[ "$answer" != "Y" ] && [ "$answer" != "y" ] && die 'New release aborted!'
	else
		release_fullname="$TWGIT_PREFIX_RELEASE$release"
	fi

	assert_valid_ref_name $release
	assert_clean_working_tree
	assert_new_local_branch $release_fullname

	process_fetch

	processing 'Check remote releases...'
	local is_remote_exists=$(has "$TWGIT_ORIGIN/$release_fullname" $(get_remote_branches) && echo 1 || echo 0)
	if [ $is_remote_exists = '1' ]; then
		processing "Remote release '$release_fullname' detected."
	fi

	exec_git_command "git checkout -b $release_fullname $last_tag" "Could not check out tag '$last_tag'!"

	process_first_commit 'release' "$release_fullname"
	process_push_branch $release_fullname $is_remote_exists
}

##
# Merge la release à la branche stable et crée un tag portant son nom s'il est compatible (major.minor.revision)
# ou récupère celui spécifié en paramètre.
#
# @param string $1 nom court de la release
# @param string $2 nom court optionnel du tag
#
function cmd_finish () {
	process_options "$@"
	require_parameter 'release'
	local release="$RETVAL"
	local release_fullname="$TWGIT_PREFIX_RELEASE$release"

	require_parameter '-'
	local tag="$RETVAL"
	[ -z "$tag" ] && tag="$release"
	local tag_fullname="$TWGIT_PREFIX_TAG$tag"

	assert_clean_working_tree
	process_fetch

	# Détection hotfixes en cours :
	local hotfix="$(get_hotfixes_in_progress)"
	[ ! -z "$hotfix" ] && die "Close a release while hotfix in progress is forbidden! Hotfix '$hotfix' must be treated first."

	# Détection tags (via hotfixes) réalisés entre temps :
	tags_not_merged="$(get_tags_not_merged_into_release $TWGIT_ORIGIN/$release_fullname | sed 's/ /, /g')"
	[ ! -z "$tags_not_merged" ] && die "You must merge following tag(s) into this release before close it: $tags_not_merged"

	processing 'Check remote features...'
	local features="$(get_features merged_in_progress $TWGIT_ORIGIN/$release_fullname)"
	[ ! -z "$features" ] && die "Features exists that are merged into this release but yet in development: '$features'!"

	processing 'Check remote releases...'
	local is_release_exists=$(has "$TWGIT_ORIGIN/$release_fullname" $(get_remote_branches) && echo 1 || echo 0)
	[ $is_release_exists = '0' ] && die "Unknown '$release_fullname' remote release! Try: twgit release list"

	has $release_fullname $(get_local_branches) && assert_branches_equal "$release_fullname" "$TWGIT_ORIGIN/$release_fullname"

	assert_valid_tag_name $tag_fullname
	processing 'Check tags...'
	local is_tag_exists=$(has "$tag_fullname" $(get_all_tags) && echo 1 || echo 0)
	[ $is_tag_exists = '1' ] && die "Tag '$tag_fullname' already exists! Try: twgit tag list"

	exec_git_command "git checkout $TWGIT_STABLE" "Could not checkout '$TWGIT_STABLE'!"
	exec_git_command "git merge --no-ff $TWGIT_ORIGIN/$TWGIT_STABLE" "Could not merge '$TWGIT_ORIGIN/$TWGIT_STABLE' into '$TWGIT_STABLE'!"
	exec_git_command "git merge --no-ff $release_fullname" "Could not merge '$release_fullname' into '$TWGIT_STABLE'!"

	processing "${TWGIT_GIT_COMMAND_PROMPT}git tag -a $tag_fullname -m \"${TWGIT_PREFIX_COMMIT_MSG}Release finish: $release_fullname\""
	git tag -a $tag_fullname -m "${TWGIT_PREFIX_COMMIT_MSG}Release finish: $release_fullname" || die "$error_msg"

	exec_git_command "git push --tags $TWGIT_ORIGIN $TWGIT_STABLE" "Could not push '$TWGIT_STABLE' on '$TWGIT_ORIGIN'!"

	# Suppression des features associées :
	features="$(get_merged_features $TWGIT_ORIGIN/$release_fullname)"
	local prefix="$TWGIT_ORIGIN/$TWGIT_PREFIX_RELEASE"
	for feature in $features; do
		remove_feature "${feature:${#prefix}}"
	done

	# Suppression de la branche :
	cmd_remove $release
}

##
# Supprime la release spécifiée.
#
# @param string $1 nom court de la release
#
function cmd_remove () {
	process_options "$@"
	require_parameter 'release'
	local release="$RETVAL"
	local release_fullname="$TWGIT_PREFIX_RELEASE$release"

	assert_valid_ref_name $release
	assert_clean_working_tree
	assert_working_tree_is_not_on_delete_branch $release_fullname

	process_fetch
	remove_local_branch $release_fullname
	remove_remote_branch $release_fullname
}

##
# Supprime la release spécifiée et en recrée une nouvelle de même nom.
# Pour se sortir des releases non viables.
#
# @param string $1 nom court de la release.
#
function cmd_reset () {
	process_options "$@"
	require_parameter 'release'
	local release="$RETVAL"
	cmd_remove $release && cmd_start $release
}
