# See bottom of file for license and copyright information

=begin TML

---+ package Foswiki::UI::Save

UI delegate for save function

=cut

package Foswiki::UI::Save;
use v5.14;

use Try::Tiny;
use Assert;

use Foswiki                 ();
use Foswiki::Meta           ();
use Foswiki::OopsException  ();
use Foswiki::Prefs::Request ();

use Moo;
use namespace::clean;
extends qw(Foswiki::UI);

BEGIN {
    if ( $Foswiki::cfg{UseLocale} ) {
        require locale;
        import locale();
    }
}

# Used by save and preview
sub buildNewTopic {
    my $this = shift;

    my ( $topicObject, $script ) = @_;

    my $app = $this->app;
    my $req = $app->request;

    unless ( $req->param() ) {

        # insufficient parameters to save
        Foswiki::OopsException->throw(
            app      => $app,
            template => 'attention',
            def      => 'bad_script_parameters',
            web      => $topicObject->web,
            topic    => $topicObject->topic,
            params   => [$script]
        );
    }

    $this->checkWebExists( $topicObject->web, 'save' );

    my $topicExists =
      $app->store->topicExists( $topicObject->web, $topicObject->topic );

    # Prevent creating a topic in a web without change access
    unless ($topicExists) {
        my $webObject =
          $this->create( 'Foswiki::Meta', web => $topicObject->web );
        $this->checkAccess( 'CHANGE', $webObject );
    }

    # Prevent saving existing topic?
    my $onlyNewTopic = Foswiki::isTrue( scalar( $req->param('onlynewtopic') ) );
    if ( $onlyNewTopic && $topicExists ) {

        # Topic exists and user requested oops if it exists
        Foswiki::OopsException->template(
            app      => $app,
            template => 'attention',
            def      => 'topic_exists',
            web      => $topicObject->web,
            topic    => $topicObject->topic
        );
    }

    # prevent non-Wiki names?
    my $onlyWikiName = Foswiki::isTrue( scalar( $req->param('onlywikiname') ) );
    if (   ($onlyWikiName)
        && ( !$topicExists )
        && ( !Foswiki::isValidTopicName( $topicObject->topic ) ) )
    {

        # do not allow non-wikinames
        Foswiki::OopsException->template(
            app      => $app,
            template => 'attention',
            def      => 'not_wikiword',
            web      => $topicObject->web,
            topic    => $topicObject->topic,
            params   => [ $topicObject->topic ]
        );
    }

    my $saveOpts = {};
    $saveOpts->{minor}            = 1 if $req->param('dontnotify');
    $saveOpts->{forcenewrevision} = 1 if $req->param('forcenewrevision');
    my ( $ancestorRev, $ancestorDate );

    my $templateTopic = $req->param('templatetopic');

    my $templateWeb = $topicObject->web;
    my $ttom;    # template topic

    my $text = $topicObject->text();

    my @attachments;
    if ($topicExists) {

        # Initialise from existing topic

        $this->checkAccess( 'VIEW',   $topicObject );
        $this->checkAccess( 'CHANGE', $topicObject );
        $text        = $topicObject->text();          # text of last rev
        $ancestorRev = $req->param('originalrev');    # rev edit started on
    }
    elsif ($templateTopic) {

        # User specified template. Validate it.

        my ( $invalidTemplateWeb, $invalidTemplateTopic ) =
          $req->normalizeWebTopicName( $templateWeb, $templateTopic );

        $templateWeb = Foswiki::Sandbox::untaint( $invalidTemplateWeb,
            \&Foswiki::Sandbox::validateWebName );
        $templateTopic = Foswiki::Sandbox::untaint( $invalidTemplateTopic,
            \&Foswiki::Sandbox::validateTopicName );

        unless ( $templateWeb && $templateTopic ) {
            Foswiki::OopsException->template(
                app      => $app,
                template => 'attention',
                def      => 'invalid_topic_parameter',
                params =>
                  [ scalar( $req->param('templatetopic') ), 'templatetopic' ]
            );
        }
        unless ( $app->store->topicExists( $templateWeb, $templateTopic ) ) {
            Foswiki::OopsException->throw(
                app      => $app,
                template => 'attention',
                def      => 'no_such_topic_template',
                web      => $templateWeb,
                topic    => $templateTopic
            );
        }

        # Initialise new topic from template topic
        $ttom = Foswiki::Meta->load( $app, $templateWeb, $templateTopic );
        $this->checkAccess( 'VIEW', $ttom );

        $text = $ttom->text();
        $text = '' if $req->param('newtopic');    # created by edit
        $topicObject->text($text);

        foreach my $k ( keys %{ $ttom->metaData } ) {

            # Skip internal fields and TOPICINFO, TOPICMOVED
            unless ( $k =~ m/^(_|TOPIC)/ ) {
                $topicObject->copyFrom( $ttom, $k );
            }

            # attachments to be copied later
            if ( $k eq 'FILEATTACHMENT' ) {
                foreach my $a ( @{ $ttom->metaData->{$k} } ) {
                    push(
                        @attachments,
                        {
                            name => $a->{name},
                            tom  => $ttom,
                        }
                    );
                }
            }
        }

        $topicObject->expandNewTopic();
        $text = $topicObject->text();

        # topic creation, there is no original rev
        $ancestorRev = 0;
    }

    # $text now contains either text from an existing topic.
    # or text obtained from a template topic. Now determine if
    # the query params will override it.
    if ( defined $req->param('text') ) {

        # text is defined in the query, save that text, overriding anything
        # from the template or the previous rev of the topic
        $text = $req->param('text');
        $text =~ s/\r//g;
        $text .= "\n" unless $text =~ m/\n$/s;
    }

    # Make sure that text is defined.
    $text = '' unless defined $text;

    # Change the parent, if appropriate
    my $newParent = $req->param('topicparent');
    if ($newParent) {
        if ( $newParent eq 'none' ) {
            $topicObject->remove('TOPICPARENT');
        }
        else {

            # Validate the new parent (it must be a legal topic name)
            my ( $vweb, $vtopic ) =
              $req->normalizeWebTopicName( $topicObject->web(), $newParent );
            $vweb = Foswiki::Sandbox::untaint( $vweb,
                \&Foswiki::Sandbox::validateWebName );
            $vtopic = Foswiki::Sandbox::untaint( $vtopic,
                \&Foswiki::Sandbox::validateTopicName );
            unless ( $vweb && $vtopic ) {
                Foswiki::OopsException->throw(
                    app      => $app,
                    template => 'attention',
                    def      => 'invalid_topic_parameter',
                    web      => $req->web,
                    topic    => $req->topic,
                    params   => [ $newParent, 'topicparent' ]
                );
            }

            # Re-untaint the raw parameter, so that a parent can be set with
            # no web specification.
            $topicObject->put( 'TOPICPARENT',
                { 'name' => Foswiki::Sandbox::untaintUnchecked($newParent) } );
        }
    }

    # Set preference values from query
    Foswiki::Prefs::Request::set( $req, $topicObject );

    my $formName = $req->param('formtemplate');
    my $formDef;

    if ($formName) {

        # new form, default field values will be null
        if ( $formName eq 'none' ) {

            # No form, remove the old data
            $topicObject->remove('FORM');
            $topicObject->remove('FIELD');
            $formName = undef;
        }
    }
    else {

        # Recover the existing form name
        my $fm = $topicObject->get('FORM');
        $formName = $fm->{name} if $fm;
    }

    if ($formName) {
        require Foswiki::Form;
        $formDef =
          Foswiki::Form->loadCached( $app, $topicObject->web, $formName );
        $topicObject->put( 'FORM', { name => $formName } );

        # Remove fields that don't exist on the new form def.
        my $filter = join( '|',
            map  { $_->{name} }
            grep { $_->{name} } @{ $formDef->getFields() } );
        foreach my $f ( $topicObject->find('FIELD') ) {
            if ( $f->{name} !~ /^($filter)$/ ) {
                $topicObject->remove( 'FIELD', $f->{name} );
            }
        }

        # override existing fields with values from the query
        my ( $seen, $missing ) =
          $formDef->getFieldValuesFromQuery( $req, $topicObject );
        if ( $seen && @$missing ) {

            # chuck up if there is at least one field value defined in the
            # query and a mandatory field was not defined in the
            # query or by an existing value.
            Foswiki::OopsException->throw(
                app      => $app,
                template => 'attention',
                def      => 'mandatory_field',
                web      => $topicObject->web,
                topic    => $topicObject->topic,
                params   => [ join( ' ', @$missing ) ]
            );
        }
    }

    if ($ancestorRev) {
        if ( $ancestorRev =~ m/^(\d+)_(\d+)$/ ) {
            ( $ancestorRev, $ancestorDate ) = ( $1, $2 );
        }
        elsif ( $ancestorRev !~ /^\d+$/ ) {

            # Badly formatted ancestor
            Foswiki::OopsException->throw(
                app      => $app,
                template => 'attention',
                def      => 'bad_script_parameters',
                web      => $topicObject->web,
                topic    => $topicObject->topic,
                params   => [$script]
            );
        }
    }

    my $merged;
    if ($ancestorRev) {

        # Get information for the most recently saved rev
        my $info = $topicObject->getRevisionInfo();

        # If the last save was done since we started the edit, and it
        # wasn't saved by the current user, we need to merge. We also
        # check the ancestor date, in case a repRev happened.
        if (
            (
                   $ancestorRev ne $info->{version}
                || $ancestorDate
                && $info->{date}
                && $ancestorDate ne $info->{date}
            )
            && $info->{author} ne $app->user
          )
        {

            # Load the prev rev again, so we can do a 3 way merge
            my $prevTopicObject =
              Foswiki::Meta->load( $app, $topicObject->web,
                $topicObject->topic );

            require Foswiki::Merge;

            $topicObject->getRevisionInfo();
            my $pti = $topicObject->get('TOPICINFO');
            if (   $pti->{reprev}
                && $pti->{version}
                && $pti->{reprev} == $pti->{version} )
            {

                # If the ancestor revision was generated by a reprev,
                # then the original is lost and we can't 3-way merge
                $app->plugins->dispatch(
                    'beforeMergeHandler', $text,
                    $pti->{version},      $prevTopicObject->text,
                    undef,                undef,
                    $topicObject->web,    $topicObject->topic
                );

                $text =
                  Foswiki::Merge::merge2( $pti->{version},
                    $prevTopicObject->text, $info->{version}, $text, '.*?\n',
                    $app );
            }
            else {

                # common ancestor; we can 3-way merge
                my $ancestorMeta =
                  Foswiki::Meta->load( $app, $topicObject->web,
                    $topicObject->topic, $ancestorRev );
                $app->plugins->dispatch(
                    'beforeMergeHandler', $text,
                    $info->{version},     $prevTopicObject->text,
                    $ancestorRev,         $ancestorMeta->text(),
                    $topicObject->web,    $topicObject->topic
                );

                $text =
                  Foswiki::Merge::merge3( $ancestorRev, $ancestorMeta->text(),
                    $info->{version}, $prevTopicObject->text, 'new', $text,
                    '.*?\n', $app );
            }
            if ($formDef) {
                $topicObject->merge( $prevTopicObject, $formDef );
            }
            $merged = [ $ancestorRev, $info->{author}, $info->{version} || 1 ];
        }
    }
    $topicObject->text($text);

    return ( $saveOpts, $merged, \@attachments );
}

=begin TML

---++ ObjectMethod expandAUTOINC($web, $topic) -> $topic
Expand AUTOINC\d+ in the topic name to the next topic name available

=cut

sub expandAUTOINC {
    my $this = shift;
    my ( $web, $topic ) = @_;

    my $app = $this->app;

    # Do not remove, keep as undocumented feature for compatibility with
    # TWiki 4.0.x: Allow for dynamic topic creation by replacing strings
    # of at least 10 x's XXXXXX with a next-in-sequence number.
    if ( $topic =~ m/X{10}/ ) {
        my $n           = 0;
        my $baseTopic   = $topic;
        my $topicObject = $this->create(
            'Foswiki::Meta',
            web   => $web,
            topic => $baseTopic
        );
        $topicObject->clearLease();
        do {
            $topic = $baseTopic;
            $topic =~ s/X{10}X*/$n/e;
            $n++;
        } while ( $app->store->topicExists( $web, $topic ) );
    }

    # Allow for more flexible topic creation with sortable names.
    # See Codev.AutoIncTopicNameOnSave
    if ( $topic =~ m/^(.*)AUTOINC(\d+)(.*)$/ ) {
        my $pre         = $1;
        my $start       = $2;
        my $pad         = length($start);
        my $post        = $3;
        my $topicObject = $this->create(
            'Foswiki::Meta',
            web   => $web,
            topic => $topic
        );
        $topicObject->clearLease();
        my $webObject = $this->create( 'Foswiki::Meta', web => $web );
        my $it = $webObject->eachTopic();

        while ( $it->hasNext() ) {
            my $tn = $it->next();
            next unless $tn =~ m/^${pre}(\d+)${post}$/;
            $start = $1 + 1 if ( $1 >= $start );
        }
        my $next = sprintf( "%0${pad}d", $start );
        $topic =~ s/AUTOINC[0-9]+/$next/;
    }
    return $topic;
}

=begin TML

---++ ObjectMethod save

Command handler for =save= command.

See System.CommandAndCGIScripts for details of parameters.

Note: =cmd= has been deprecated in favour of =action=. It will be deleted at
some point.

=cut

sub save {
    my $this = shift;

    my $app = $this->app;
    my $req = $app->request;
    my $cfg = $app->cfg;

    my $saveaction = '';
    foreach my $action (
        qw( save checkpoint quietsave cancel preview
        addform replaceform delRev repRev )
      )
    {
        if ( $req->param( 'action_' . $action ) ) {
            $saveaction = $action;
            last;
        }
    }

    # the 'action' parameter has been deprecated, though is still available
    # for compatibility with old templates.
    if ( !$saveaction && $req->param('action') ) {
        $saveaction = lc( $req->param('action') );
        $app->logger->log( 'warning', <<WARN);
Use of deprecated "action" parameter to "save". Correct your templates!
WARN

        # handle old values for form-related actions:
        $saveaction = 'addform'     if ( $saveaction eq 'add form' );
        $saveaction = 'replaceform' if ( $saveaction eq 'replace form...' );
    }

    if ( $saveaction eq 'preview' ) {
        $this->create('Foswiki::UI::Preview')->preview;
        return;
    }

    my ( $web, $topic ) = $req->normalizeWebTopicName( $req->web, $req->topic );

    if ( $req->invalidTopic ) {
        Foswiki::OopsException->throw(
            app      => $app,
            template => 'accessdenied',
            status   => 404,
            def      => 'invalid_topic_name',
            web      => $web,
            topic    => $topic,
            params   => [ $req->invalidTopic ]
        );
    }

    $topic = $this->expandAUTOINC( $web, $topic );

    my $topicObject =
      $this->create( 'Foswiki::Meta', web => $web, topic => $topic );

    if ( $saveaction eq 'cancel' ) {
        my $lease = $topicObject->getLease();
        if ( $lease && $lease->{user} eq $app->user ) {
            $topicObject->clearLease();
        }

        # redirect to a sensible place (a topic that exists)
        my ( $w, $t ) = ( '', '' );
        foreach my $test (
            $topic,
            scalar( $req->param('topicparent') ),
            $cfg->data->{HomeTopicName}
          )
        {
            ( $w, $t ) = $req->normalizeWebTopicName( $web, $test );

            # Validate topic name
            $t = Foswiki::Sandbox::untaint( $t,
                \&Foswiki::Sandbox::validateTopicName );
            last if ( $app->store->topicExists( $w, $t ) );
        }
        $app->redirect( $app->redirectto("$w.$t") );

        return;
    }

    # Do this *before* we do any query parameter rewriting
    $this->checkValidationKey;

    my $editaction = lc( $req->param('editaction') || '' );
    my $edit = $req->param('edit') || 'edit';

    ## SMELL: The form affecting actions do not preserve edit and editparams
    # preview+submitChangeForm is deprecated undocumented legacy
    if (   $saveaction eq 'addform'
        || $saveaction eq 'replaceform'
        || $saveaction eq 'preview' && $req->param('submitChangeForm') )
    {
        require Foswiki::UI::ChangeForm;
        $app->writeCompletePage( $this->create('Foswiki::UI::ChangeForm')
              ->generate( $topicObject, $editaction ) );
        return;
    }

    my $redirecturl;

    if ( $saveaction eq 'checkpoint' ) {
        $req->param( -name => 'dontnotify', -value => 'checked' );
        my $edittemplate = $req->param('template');
        my %p = ( t => time() );

        # map editaction -> action and edittemplat -> template
        $p{action}   = $editaction   if $editaction;
        $p{template} = $edittemplate if $edittemplate;

        # Pass through selected parameters
        foreach my $pthru (qw(redirectto skin cover nowysiwyg action)) {
            $p{$pthru} = $req->param($pthru);
        }

        $redirecturl = $app->cfg->getScriptUrl( 1, $edit, $web, $topic, %p );

        $redirecturl .= $req->param('editparams')
          if $req->param('editparams');    # May contain anchor

        my $lease = $topicObject->getLease();

        if ( $lease && $lease->{user} eq $app->user ) {
            $topicObject->setLease( $cfg->data->{LeaseLength} );
        }

        # drop through
    }
    else {

        # redirect to topic view or any other redirectto
        # specified as an url param
        $redirecturl = $app->redirectto("$web.$topic");
    }

    if ( $saveaction eq 'quietsave' ) {
        $req->param( -name => 'dontnotify', -value => 'checked' );
        $saveaction = 'save';

        # drop through
    }

    if ( $saveaction =~ m/^(del|rep)Rev$/ ) {

        # hidden, largely undocumented functions, used by administrators for
        # reverting spammed topics. These functions support rewriting
        # history, in a Joe Stalin kind of way. They should be replaced with
        # mechanisms for hiding revisions.
        $req->param( -name => 'cmd', -value => $saveaction );

        # drop through
    }

    my $adminCmd = $req->param('cmd') || 0;
    if ( $adminCmd && !$app->users->isAdmin( $app->user ) ) {
        Foswiki::OopsException->throw(
            app      => $app,
            template => 'accessdenied',
            status   => 403,
            def      => 'only_group',
            web      => $web,
            topic    => $topic,
            params   => [ $cfg->data->{SuperAdminGroup} ]
        );
    }

    if ( $adminCmd eq 'delRev' ) {

        # delete top revision
        try {
            $topicObject->deleteMostRecentRevision();
        }
        catch {
            $app->logger->log( 'error', ( ref($_) ? $_->text : $_ ) );
            Foswiki::OopsException->rethrowAs(
                $_,
                app      => $app,
                template => 'attention',
                def      => 'save_error',
                web      => $web,
                topic    => $topic,
                params   => [
                    $app->i18n->maketext(
                        'Operation [_1] failed with an internal error',
                        'delRev'
                    )
                ],
            );

        };

        $app->redirect($redirecturl);
        return;
    }

    if ( $adminCmd eq 'repRev' ) {

        # replace top revision with the text from the query, trying to
        # make it look as much like the original as possible. The query
        # text is expected to contain %META as well as text.
        $topicObject->text( scalar $req->param('text') );

        try {
            $topicObject->replaceMostRecentRevision( forcedate => 1 );
        }
        catch {
            $app->logger->log( 'error', ( ref($_) ? $_->text : $_ ) );
            Foswiki::OopsException->rethrowAs(
                $_,
                app      => $app,
                template => 'attention',
                def      => 'save_error',
                web      => $web,
                topic    => $topic,
                params   => [
                    $app->i18n->maketext(
                        'Operation [_1] failed with an internal error',
                        'repRev'
                    )
                ],
            );

        };

        $app->redirect($redirecturl);
        return;
    }

    # This is where the permissions are checked.  Error will be thrown
    # if the save won't be allowed.
    my ( $saveOpts, $merged, $attachments ) =
      $this->buildNewTopic( $topicObject, 'save' );

    if ( $saveaction =~ m/^(save|checkpoint)$/ ) {
        my $text = $topicObject->text();
        $text = '' unless defined $text;
        $app->plugins->dispatch( 'afterEditHandler', $text,
            $topicObject->topic, $topicObject->web, $topicObject );
        $topicObject->text($text);
    }

    try {
        $topicObject->save(%$saveOpts);
    }
    catch {
        $app->logger->log( 'error', ( ref($_) ? $_->text : $_ ) );
        Foswiki::OopsException->rethrowAs(
            $_,
            app      => $app,
            template => 'attention',
            def      => 'save_error',
            web      => $topicObject->web,
            topic    => $topicObject->topic,
            params   => [
                $app->i18n->maketext(
                    'Operation [_1] failed with an internal error', 'save'
                )
            ],
        );
    };

    # Final version created during merge.
    if ($merged) {
        my $savedInfo = $topicObject->getRevisionInfo();
        push @$merged, $savedInfo->{version};
    }

    if ($attachments) {
        foreach $a ( @{$attachments} ) {
            try {
                $a->{tom}->copyAttachment( $a->{name}, $topicObject );
            }
            catch {
                $app->logger->log( 'error', ( ref($_) ? $_->text : $_ ) );
                Foswiki::OopsException->rethrowAs(
                    $_,
                    app      => $app,
                    template => 'attention',
                    def      => 'save_error',
                    web      => $topicObject->web,
                    topic    => $topicObject->topic,
                    params   => [
                        $app->i18n->maketext(
                            'Operation [_1] failed with an internal error',
                            'copyAttachment'
                        )
                    ],
                );
            };
        }
    }

    my $lease = $topicObject->getLease();

    # clear the lease, if (and only if) we own it
    if ( $lease && $lease->{user} eq $app->user ) {
        $topicObject->clearLease();
    }

    if ($merged) {
        Foswiki::OopsException->throw(
            app      => $app,
            template => 'attention',
            status   => 200,
            def      => 'merge_notice',
            web      => $topicObject->web,
            topic    => $topicObject->topic,
            params   => $merged
        );
    }

    $app->redirect($redirecturl);
}

1;
__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2008-2010 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

Additional copyrights apply to some or all of the code in this
file as follows:

Copyright (C) 1999-2007 Peter Thoeny, peter@thoeny.org
and TWiki Contributors. All Rights Reserved.
Based on parts of Ward Cunninghams original Wiki and JosWiki.
Copyright (C) 1998 Markus Peter - SPiN GmbH (warpi@spin.de)
Some changes by Dave Harris (drh@bhresearch.co.uk) incorporated

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
